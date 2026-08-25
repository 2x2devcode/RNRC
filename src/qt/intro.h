#ifndef INTRO_H
#define INTRO_H

#include <QDialog>

class QLabel;
class QLineEdit;
class QPushButton;

/** First-run / missing-datadir screen.
 *  Lets the user choose the wallet data directory and optionally point to a
 *  bootstrap.dat (or compressed) file for automatic blockchain import.
 *
 *  Do NOT call GetDataDir() before Intro::pickDataDirectory() — that caches
 *  the wrong path.
 */
class Intro : public QDialog
{
    Q_OBJECT

public:
    explicit Intro(QWidget *parent = 0);
    ~Intro();

    QString getDataDirectory() const;
    void setDataDirectory(const QString &dataDir);

    QString getBootstrapPath() const;
    void setBootstrapPath(const QString &path);
    void setStatusMessage(const QString &message);

    /** Decide datadir: use CLI, restore from QSettings, or show this dialog.
     *  On success SoftSets -datadir when needed and stages bootstrap.dat.
     *  @return false if the user cancelled.
     */
    static bool pickDataDirectory();

    /** Copy or decompress bootstrap into dataDir/bootstrap.dat for AppInit import. */
    static bool prepareBootstrap(const QString &dataDir, const QString &bootstrapSource, QString *errorMessage = 0);

private slots:
    void onDataDirBrowse();
    void onBootstrapBrowse();
    void onUseDefaultDataDir();
    void accept();

private:
    QLineEdit *dataDirEdit;
    QLineEdit *bootstrapEdit;
    QLabel *statusLabel;
    QString defaultDataDir;
};

#endif // INTRO_H
