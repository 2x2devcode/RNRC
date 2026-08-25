#include "intro.h"

#include "util.h"

#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileDialog>
#include <QFileInfo>
#include <QFont>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QMessageBox>
#include <QProcess>
#include <QPushButton>
#include <QSettings>
#include <QVBoxLayout>

#include <cstring>

extern "C" {
#include <zlib.h>
}

static QString defaultDataDirString()
{
    return QString::fromStdString(GetDefaultDataDir().string());
}

static bool ensureDirectory(const QString &path, QString *errorMessage)
{
    QDir dir(path);
    if (dir.exists())
        return true;
    if (QDir().mkpath(path))
        return true;
    if (errorMessage)
        *errorMessage = Intro::tr("Error: Specified data directory \"%1\" cannot be created.").arg(path);
    return false;
}

/** Stream-inflate a gzip file to destPath. */
static bool gunzipFile(const QString &srcPath, const QString &destPath, QString *errorMessage)
{
    QFile in(srcPath);
    if (!in.open(QIODevice::ReadOnly)) {
        if (errorMessage)
            *errorMessage = Intro::tr("Cannot open bootstrap file \"%1\".").arg(srcPath);
        return false;
    }

    QFile out(destPath);
    if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        if (errorMessage)
            *errorMessage = Intro::tr("Cannot write bootstrap file to \"%1\".").arg(destPath);
        return false;
    }

    z_stream strm;
    std::memset(&strm, 0, sizeof(strm));
    // 15 + 16 = decode gzip wrapper
    if (inflateInit2(&strm, 15 + 16) != Z_OK) {
        if (errorMessage)
            *errorMessage = Intro::tr("Failed to initialize gzip decompressor.");
        return false;
    }

    const int chunk = 256 * 1024;
    QByteArray inBuf(chunk, Qt::Uninitialized);
    QByteArray outBuf(chunk, Qt::Uninitialized);
    int ret = Z_OK;

    do {
        qint64 nread = in.read(inBuf.data(), chunk);
        if (nread < 0) {
            inflateEnd(&strm);
            out.close();
            out.remove();
            if (errorMessage)
                *errorMessage = Intro::tr("Failed to read \"%1\".").arg(srcPath);
            return false;
        }
        strm.avail_in = static_cast<uInt>(nread);
        strm.next_in = reinterpret_cast<Bytef*>(inBuf.data());

        if (strm.avail_in == 0 && ret != Z_STREAM_END)
            break;

        do {
            strm.avail_out = chunk;
            strm.next_out = reinterpret_cast<Bytef*>(outBuf.data());
            ret = inflate(&strm, Z_NO_FLUSH);
            if (ret == Z_NEED_DICT || ret == Z_DATA_ERROR || ret == Z_MEM_ERROR) {
                inflateEnd(&strm);
                out.close();
                out.remove();
                if (errorMessage)
                    *errorMessage = Intro::tr("Failed to decompress \"%1\".").arg(srcPath);
                return false;
            }
            int have = chunk - static_cast<int>(strm.avail_out);
            if (have > 0 && out.write(outBuf.constData(), have) != have) {
                inflateEnd(&strm);
                out.close();
                out.remove();
                if (errorMessage)
                    *errorMessage = Intro::tr("Failed while writing decompressed bootstrap data.");
                return false;
            }
        } while (strm.avail_out == 0);
    } while (ret != Z_STREAM_END);

    inflateEnd(&strm);
    out.close();

    if (ret != Z_STREAM_END) {
        out.remove();
        if (errorMessage)
            *errorMessage = Intro::tr("File \"%1\" is not a valid gzip archive.").arg(srcPath);
        return false;
    }
    return true;
}

/** Extract bootstrap.dat from a zip into destDir. */
static bool unzipBootstrap(const QString &zipPath, const QString &destDir, QString *errorMessage)
{
    QDir().mkpath(destDir);
    const QString destFile = QDir(destDir).filePath("bootstrap.dat");

#ifdef WIN32
    {
        const QString tempDir = QDir(destDir).filePath(".bootstrap-extract");
        QDir(tempDir).removeRecursively();
        QDir().mkpath(tempDir);

        const QString script = QString(
            "$ErrorActionPreference='Stop'; "
            "Expand-Archive -LiteralPath '%1' -DestinationPath '%2' -Force")
            .arg(QDir::toNativeSeparators(zipPath).replace("'", "''"),
                 QDir::toNativeSeparators(tempDir).replace("'", "''"));

        QProcess proc;
        proc.start("powershell", QStringList() << "-NoProfile" << "-Command" << script);
        if (proc.waitForFinished(-1) && proc.exitCode() == 0) {
            QString found;
            QDirIterator it(tempDir, QStringList() << "bootstrap.dat", QDir::Files, QDirIterator::Subdirectories);
            if (it.hasNext())
                found = it.next();
            if (found.isEmpty()) {
                QDir(tempDir).removeRecursively();
                if (errorMessage)
                    *errorMessage = Intro::tr("Zip archive does not contain bootstrap.dat.");
                return false;
            }
            QFile::remove(destFile);
            const bool ok = QFile::copy(found, destFile);
            QDir(tempDir).removeRecursively();
            if (!ok) {
                if (errorMessage)
                    *errorMessage = Intro::tr("Failed to copy bootstrap.dat from zip archive.");
                return false;
            }
            return true;
        }
        QDir(tempDir).removeRecursively();
    }
#endif

    QProcess unzip;
    unzip.setWorkingDirectory(destDir);
    unzip.start("unzip", QStringList() << "-o" << "-j" << zipPath << "bootstrap.dat");
    if (unzip.waitForFinished(-1) && unzip.exitCode() == 0 && QFile::exists(destFile))
        return true;

    unzip.start("unzip", QStringList() << "-o" << zipPath << "-d" << destDir);
    if (!unzip.waitForFinished(-1) || unzip.exitCode() != 0) {
        if (errorMessage)
            *errorMessage = Intro::tr("Failed to extract zip archive \"%1\". Install unzip or provide bootstrap.dat / .gz.").arg(zipPath);
        return false;
    }

    if (!QFile::exists(destFile)) {
        QDirIterator it(destDir, QStringList() << "bootstrap.dat", QDir::Files, QDirIterator::Subdirectories);
        if (!it.hasNext()) {
            if (errorMessage)
                *errorMessage = Intro::tr("Zip archive does not contain bootstrap.dat.");
            return false;
        }
        const QString found = it.next();
        if (found != destFile) {
            QFile::remove(destFile);
            if (!QFile::copy(found, destFile)) {
                if (errorMessage)
                    *errorMessage = Intro::tr("Failed to copy bootstrap.dat from zip archive.");
                return false;
            }
        }
    }
    return QFile::exists(destFile);
}

static QString resolveBootstrapSource(const QString &input)
{
    if (input.isEmpty())
        return QString();

    QFileInfo fi(input);
    if (fi.isFile())
        return fi.absoluteFilePath();

    if (fi.isDir()) {
        QDir dir(fi.absoluteFilePath());
        const char *candidates[] = {
            "bootstrap.dat",
            "bootstrap.dat.gz",
            "bootstrap.dat.zip",
            "bootstrap.zip",
            "bootstrap.gz",
            0
        };
        for (int i = 0; candidates[i]; ++i) {
            const QString path = dir.filePath(QString::fromUtf8(candidates[i]));
            if (QFile::exists(path))
                return path;
        }
        const QStringList matches = dir.entryList(QStringList() << "bootstrap*", QDir::Files);
        if (!matches.isEmpty())
            return dir.filePath(matches.first());
    }
    return QString();
}

bool Intro::prepareBootstrap(const QString &dataDir, const QString &bootstrapSource, QString *errorMessage)
{
    const QString source = resolveBootstrapSource(bootstrapSource);
    if (source.isEmpty()) {
        if (!bootstrapSource.trimmed().isEmpty()) {
            if (errorMessage)
                *errorMessage = tr("Bootstrap path \"%1\" was not found.").arg(bootstrapSource);
            return false;
        }
        return true;
    }

    if (!ensureDirectory(dataDir, errorMessage))
        return false;

    const QString dest = QDir(dataDir).filePath("bootstrap.dat");
    const QFileInfo sfi(source);
    const QString name = sfi.fileName().toLower();

    if (QFileInfo(source).absoluteFilePath() == QFileInfo(dest).absoluteFilePath())
        return true;

    QFile::remove(dest);

    if (name.endsWith(QLatin1String(".zip")))
        return unzipBootstrap(source, dataDir, errorMessage);

    if (name.endsWith(QLatin1String(".gz")))
        return gunzipFile(source, dest, errorMessage);

    if (name.endsWith(QLatin1String(".dat"))) {
        if (!QFile::copy(source, dest)) {
            if (errorMessage)
                *errorMessage = tr("Failed to copy bootstrap.dat to the data directory.");
            return false;
        }
        return true;
    }

    if (!QFile::copy(source, dest)) {
        if (errorMessage)
            *errorMessage = tr("Unsupported bootstrap file \"%1\".").arg(source);
        return false;
    }
    return true;
}

Intro::Intro(QWidget *parent) :
    QDialog(parent),
    dataDirEdit(0),
    bootstrapEdit(0),
    statusLabel(0)
{
    setWindowTitle(tr("Welcome to RNRC"));
    setModal(true);
    resize(560, 320);

    defaultDataDir = defaultDataDirString();

    QVBoxLayout *root = new QVBoxLayout(this);

    QLabel *title = new QLabel(tr("Choose where to store your wallet and blockchain data."));
    title->setWordWrap(true);
    QFont titleFont = title->font();
    titleFont.setPointSize(titleFont.pointSize() + 2);
    titleFont.setBold(true);
    title->setFont(titleFont);
    root->addWidget(title);

    QLabel *explain = new QLabel(tr(
        "On first use, or if the previously saved data folder was not found, "
        "select a folder for RNRC. You can optionally point to a downloaded "
        "bootstrap.dat (or a folder containing it, or a .gz / .zip) to speed up the initial sync."));
    explain->setWordWrap(true);
    root->addWidget(explain);

    QFormLayout *form = new QFormLayout();
    form->setFieldGrowthPolicy(QFormLayout::ExpandingFieldsGrow);

    QWidget *dataRow = new QWidget(this);
    QHBoxLayout *dataLay = new QHBoxLayout(dataRow);
    dataLay->setContentsMargins(0, 0, 0, 0);
    dataDirEdit = new QLineEdit(dataRow);
    dataDirEdit->setText(defaultDataDir);
    QPushButton *dataBrowse = new QPushButton(tr("Browse..."), dataRow);
    QPushButton *dataDefault = new QPushButton(tr("Default"), dataRow);
    dataLay->addWidget(dataDirEdit, 1);
    dataLay->addWidget(dataBrowse);
    dataLay->addWidget(dataDefault);
    form->addRow(tr("Data directory"), dataRow);

    QWidget *bootRow = new QWidget(this);
    QHBoxLayout *bootLay = new QHBoxLayout(bootRow);
    bootLay->setContentsMargins(0, 0, 0, 0);
    bootstrapEdit = new QLineEdit(bootRow);
    bootstrapEdit->setPlaceholderText(tr("Optional: folder or bootstrap.dat / .gz / .zip"));
    QPushButton *bootBrowse = new QPushButton(tr("Browse..."), bootRow);
    bootLay->addWidget(bootstrapEdit, 1);
    bootLay->addWidget(bootBrowse);
    form->addRow(tr("Bootstrap file"), bootRow);

    root->addLayout(form);

    statusLabel = new QLabel(this);
    statusLabel->setWordWrap(true);
    statusLabel->setStyleSheet(QLatin1String("color: #a63d00;"));
    root->addWidget(statusLabel);

    root->addStretch(1);

    QHBoxLayout *buttons = new QHBoxLayout();
    buttons->addStretch(1);
    QPushButton *cancel = new QPushButton(tr("Cancel"), this);
    QPushButton *ok = new QPushButton(tr("OK"), this);
    ok->setDefault(true);
    buttons->addWidget(cancel);
    buttons->addWidget(ok);
    root->addLayout(buttons);

    connect(dataBrowse, SIGNAL(clicked()), this, SLOT(onDataDirBrowse()));
    connect(dataDefault, SIGNAL(clicked()), this, SLOT(onUseDefaultDataDir()));
    connect(bootBrowse, SIGNAL(clicked()), this, SLOT(onBootstrapBrowse()));
    connect(cancel, SIGNAL(clicked()), this, SLOT(reject()));
    connect(ok, SIGNAL(clicked()), this, SLOT(accept()));
}

Intro::~Intro()
{
}

QString Intro::getDataDirectory() const
{
    return dataDirEdit ? dataDirEdit->text().trimmed() : QString();
}

void Intro::setDataDirectory(const QString &dataDir)
{
    if (dataDirEdit)
        dataDirEdit->setText(dataDir);
}

QString Intro::getBootstrapPath() const
{
    return bootstrapEdit ? bootstrapEdit->text().trimmed() : QString();
}

void Intro::setBootstrapPath(const QString &path)
{
    if (bootstrapEdit)
        bootstrapEdit->setText(path);
}

void Intro::setStatusMessage(const QString &message)
{
    if (statusLabel)
        statusLabel->setText(message);
}

void Intro::onDataDirBrowse()
{
    const QString dir = QFileDialog::getExistingDirectory(this, tr("Choose data directory"), getDataDirectory());
    if (!dir.isEmpty())
        setDataDirectory(dir);
}

void Intro::onUseDefaultDataDir()
{
    setDataDirectory(defaultDataDir);
}

void Intro::onBootstrapBrowse()
{
    QString start = getBootstrapPath();
    if (start.isEmpty())
        start = QDir::homePath();

    // Prefer a folder (as requested); user may also type a file path.
    QMessageBox choice(this);
    choice.setWindowTitle(tr("Bootstrap"));
    choice.setText(tr("Select a folder that contains bootstrap.dat, or pick the file directly."));
    QPushButton *folderBtn = choice.addButton(tr("Folder..."), QMessageBox::AcceptRole);
    QPushButton *fileBtn = choice.addButton(tr("File..."), QMessageBox::ActionRole);
    choice.addButton(QMessageBox::Cancel);
    choice.exec();

    QString path;
    if (choice.clickedButton() == folderBtn) {
        path = QFileDialog::getExistingDirectory(this, tr("Choose folder containing bootstrap.dat"), start);
    } else if (choice.clickedButton() == fileBtn) {
        path = QFileDialog::getOpenFileName(this, tr("Choose bootstrap file"), start,
            tr("Bootstrap (bootstrap.dat *.dat *.gz *.zip);;All files (*)"));
    }
    if (!path.isEmpty())
        setBootstrapPath(path);
}

void Intro::accept()
{
    const QString dataDir = getDataDirectory();
    if (dataDir.isEmpty()) {
        setStatusMessage(tr("Please choose a data directory."));
        return;
    }

    QString err;
    if (!ensureDirectory(dataDir, &err)) {
        setStatusMessage(err);
        return;
    }

    const QString bootstrap = getBootstrapPath();
    if (!bootstrap.isEmpty()) {
        if (!prepareBootstrap(dataDir, bootstrap, &err)) {
            setStatusMessage(err);
            return;
        }
    }

    QDialog::accept();
}

bool Intro::pickDataDirectory()
{
    // Explicit -datadir on the command line: caller already validated existence.
    if (mapArgs.count("-datadir"))
        return true;

    QSettings settings;
    QString dataDir = settings.value(QLatin1String("strDataDir")).toString();
    const QString defaultDir = defaultDataDirString();

    // Previously chosen directory still present — reuse without dialog.
    if (!dataDir.isEmpty() && QDir(dataDir).exists()) {
        if (dataDir != defaultDir)
            SoftSetArg("-datadir", dataDir.toStdString());
        return true;
    }

    Intro intro;
    if (!dataDir.isEmpty() && !QDir(dataDir).exists()) {
        intro.setDataDirectory(dataDir);
        intro.setStatusMessage(tr("The previously saved data directory \"%1\" was not found. Please choose a new location.").arg(dataDir));
    } else {
        intro.setDataDirectory(defaultDir);
    }

    while (true) {
        if (intro.exec() != QDialog::Accepted)
            return false;

        dataDir = intro.getDataDirectory();
        QString err;
        if (!ensureDirectory(dataDir, &err)) {
            QMessageBox::critical(0, tr("RNRC"), err);
            continue;
        }

        settings.setValue(QLatin1String("strDataDir"), dataDir);

        if (dataDir != defaultDir)
            SoftSetArg("-datadir", dataDir.toStdString());

        // Prime GetDataDir cache only after -datadir SoftSet and directory exists.
        try {
            (void)GetDataDir(/*fNetSpecific=*/false);
        } catch (...) {
            QMessageBox::critical(0, tr("RNRC"),
                tr("Error: Specified data directory \"%1\" cannot be created.").arg(dataDir));
            continue;
        }
        return true;
    }
}
