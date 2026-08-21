// Copyright (c) 2024 RNRC Developers
// Distributed under the MIT/X11 software license.

#include "networkpage.h"
#include "peertablemodel.h"
#include "clientmodel.h"
#include "guiutil.h"
#include "guiconstants.h"

#include "net.h"
#include "main.h"

#include <QDateTime>
#include <QFormLayout>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QLabel>
#include <QPushButton>
#include <QScrollArea>
#include <QSortFilterProxyModel>
#include <QSplitter>
#include <QTableView>
#include <QTimer>
#include <QTcpSocket>
#include <QVBoxLayout>
#include <QFrame>
#include <QFont>

// ---------------------------------------------------------------------------
// Hardcoded seed list — must match net.cpp seeds / RNRC.conf examples
// ---------------------------------------------------------------------------
static const char* KNOWN_SEEDS[] = {
    "149.102.139.53:18355",
    "185.249.199.205:18355",
    "121.142.85.242:18355",
    "82.37.112.143:18355",
    "124.80.22.122:18355",
    "59.151.213.58:18355",
    "116.39.234.10:18355",
    "59.187.208.96:18355",
    "175.198.107.166:18355",
    "96.42.3.145:18355",
    NULL
};

static const int SEED_TCP_TIMEOUT_MS = 3000;

// ---------------------------------------------------------------------------

NetworkPage::NetworkPage(QWidget *parent)
    : QWidget(parent),
      clientModel(0),
      peerModel(0),
      proxyModel(0),
      fRefreshing(false),
      fCheckingSeeds(false),
      lblConnections(0),
      lblBlocks(0),
      lblLastBlock(0),
      peersTable(0),
      refreshButton(0),
      seedCheckTimer(0)
{
    // ---- top-level layout -------------------------------------------------
    QVBoxLayout *mainLayout = new QVBoxLayout(this);
    mainLayout->setContentsMargins(8, 8, 8, 8);
    mainLayout->setSpacing(8);

    // Title
    QLabel *title = new QLabel(tr("<b>Network</b>"), this);
    QFont tf = title->font();
    tf.setPointSize(tf.pointSize() + 2);
    title->setFont(tf);
    mainLayout->addWidget(title);

    // ---- refresh button ---------------------------------------------------
    refreshButton = new QPushButton(tr("Refresh"), this);
    refreshButton->setMaximumWidth(120);
    // Manual refresh may run seed TCP probes; block/connection signals must not.
    connect(refreshButton, SIGNAL(clicked()), this, SLOT(refreshAll()));

    // ---- horizontal splitter: left=seeds, right=peers --------------------
    QSplitter *splitter = new QSplitter(Qt::Horizontal, this);

    // ---- LEFT: summary + seed nodes --------------------------------------
    QWidget *leftPane = new QWidget(splitter);
    QVBoxLayout *leftLayout = new QVBoxLayout(leftPane);
    leftLayout->setContentsMargins(4, 4, 4, 4);

    buildSummarySection();

    QGroupBox *summaryBox = new QGroupBox(tr("Summary"), leftPane);
    QFormLayout *summaryForm = new QFormLayout(summaryBox);
    summaryForm->setLabelAlignment(Qt::AlignRight);
    summaryForm->addRow(tr("Connections:"), lblConnections);
    summaryForm->addRow(tr("Best Block:"),  lblBlocks);
    summaryForm->addRow(tr("Last Block:"),  lblLastBlock);
    leftLayout->addWidget(summaryBox);

    buildSeedSection();

    QGroupBox *seedBox = new QGroupBox(tr("Seed Nodes"), leftPane);
    QVBoxLayout *seedLayout = new QVBoxLayout(seedBox);
    seedLayout->setSpacing(4);
    for (int i = 0; i < seedAddresses.size(); ++i)
    {
        QHBoxLayout *row = new QHBoxLayout();
        QLabel *addr = new QLabel(seedAddresses[i], seedBox);
        addr->setTextInteractionFlags(Qt::TextSelectableByMouse);
        row->addWidget(seedStatusLabels[i], 0);
        row->addWidget(addr, 1);
        seedLayout->addLayout(row);
    }
    leftLayout->addWidget(seedBox);
    leftLayout->addStretch();
    leftPane->setLayout(leftLayout);

    // ---- RIGHT: connected peers ------------------------------------------
    QWidget *rightPane = new QWidget(splitter);
    QVBoxLayout *rightLayout = new QVBoxLayout(rightPane);
    rightLayout->setContentsMargins(4, 4, 4, 4);

    buildPeerSection();

    QGroupBox *peersBox = new QGroupBox(tr("Connected Peers"), rightPane);
    QVBoxLayout *peersBoxLayout = new QVBoxLayout(peersBox);
    peersBoxLayout->addWidget(peersTable);
    rightLayout->addWidget(peersBox);
    rightPane->setLayout(rightLayout);

    splitter->addWidget(leftPane);
    splitter->addWidget(rightPane);
    splitter->setStretchFactor(0, 0);
    splitter->setStretchFactor(1, 1);

    mainLayout->addWidget(splitter, 1);

    // ---- bottom bar ------------------------------------------------------
    QHBoxLayout *bottomBar = new QHBoxLayout();
    bottomBar->addStretch();
    bottomBar->addWidget(refreshButton);
    mainLayout->addLayout(bottomBar);

    // Seed TCP probes are slow/blocking — keep them on a slow timer only,
    // never on every numBlocksChanged during IBD.
    seedCheckTimer = new QTimer(this);
    seedCheckTimer->setInterval(60 * 1000);
    connect(seedCheckTimer, SIGNAL(timeout()), this, SLOT(checkSeedConnectivity()));
}

NetworkPage::~NetworkPage()
{
}

// ---------------------------------------------------------------------------
// setClientModel
// ---------------------------------------------------------------------------
void NetworkPage::setClientModel(ClientModel *model)
{
    clientModel = model;
    if (!model)
        return;

    // Create the peer table model backed by this client model
    peerModel = new PeerTableModel(model);
    proxyModel = new QSortFilterProxyModel(this);
    proxyModel->setSourceModel(peerModel);
    proxyModel->setSortCaseSensitivity(Qt::CaseInsensitive);
    peersTable->setModel(proxyModel);
    peersTable->sortByColumn(PeerTableModel::Address, Qt::AscendingOrder);
    peersTable->horizontalHeader()->setResizeMode(PeerTableModel::Address,    QHeaderView::Stretch);
    peersTable->horizontalHeader()->setResizeMode(PeerTableModel::UserAgent,  QHeaderView::ResizeToContents);
    peersTable->horizontalHeader()->setResizeMode(PeerTableModel::Version,    QHeaderView::ResizeToContents);
    peersTable->horizontalHeader()->setResizeMode(PeerTableModel::Direction,  QHeaderView::ResizeToContents);
    peersTable->horizontalHeader()->setResizeMode(PeerTableModel::Connected,  QHeaderView::ResizeToContents);
    peersTable->horizontalHeader()->setResizeMode(PeerTableModel::StartHeight,QHeaderView::ResizeToContents);
    peersTable->horizontalHeader()->setResizeMode(PeerTableModel::BanScore,   QHeaderView::ResizeToContents);

    // Connections: refresh peer rows. Blocks: summary labels only (no model reset).
    connect(model, SIGNAL(numConnectionsChanged(int)), this, SLOT(refresh()));
    connect(model, SIGNAL(numBlocksChanged(int,int)), this, SLOT(updateSummary()));

    peerModel->startAutoRefresh();
    seedCheckTimer->start();
    refresh();
    // Defer first seed probe until after the UI is up and IBD has a chance to
    // settle. waitForConnected can still spin nested Qt events on Windows.
    QTimer::singleShot(60 * 1000, this, SLOT(checkSeedConnectivity()));
}

// ---------------------------------------------------------------------------
// Build helpers
// ---------------------------------------------------------------------------
void NetworkPage::buildSummarySection()
{
    lblConnections = new QLabel("–", this);
    lblBlocks      = new QLabel("–", this);
    lblLastBlock   = new QLabel("–", this);
}

void NetworkPage::buildSeedSection()
{
    for (int i = 0; KNOWN_SEEDS[i] != NULL; ++i)
    {
        seedAddresses.append(QString::fromLatin1(KNOWN_SEEDS[i]));
        QLabel *dot = new QLabel(statusDot(0), this);  // grey = unknown
        dot->setTextFormat(Qt::RichText);
        seedStatusLabels.append(dot);
    }
}

void NetworkPage::buildPeerSection()
{
    peersTable = new QTableView(this);
    peersTable->setSelectionBehavior(QAbstractItemView::SelectRows);
    peersTable->setSelectionMode(QAbstractItemView::SingleSelection);
    peersTable->setSortingEnabled(true);
    peersTable->setEditTriggers(QAbstractItemView::NoEditTriggers);
    peersTable->setAlternatingRowColors(true);
    peersTable->verticalHeader()->hide();
    peersTable->setShowGrid(false);
}

// ---------------------------------------------------------------------------
// Status dot HTML helper
// ---------------------------------------------------------------------------
QString NetworkPage::statusDot(int state)
{
    QString color;
    switch (state) {
    case 1:  color = "#27ae60"; break;  // green
    case 2:  color = "#e74c3c"; break;  // red
    default: color = "#95a5a6"; break;  // grey
    }
    return QString("<font color=\"%1\">\xe2\x97\x8f</font>").arg(color);
}

// ---------------------------------------------------------------------------
// Summary labels only
// ---------------------------------------------------------------------------
void NetworkPage::updateSummary()
{
    if (!clientModel)
        return;

    int conn    = clientModel->getNumConnections();
    int blocks  = clientModel->getNumBlocks();
    QDateTime dt = clientModel->getLastBlockDate();

    lblConnections->setText(QString::number(conn));
    lblBlocks->setText(QString::number(blocks));
    lblLastBlock->setText(GUIUtil::dateTimeStr(dt));
}

// ---------------------------------------------------------------------------
// Public slot: lightweight refresh (peers + summary). Safe during IBD.
// ---------------------------------------------------------------------------
void NetworkPage::refresh()
{
    if (fRefreshing)
        return;
    // Avoid peer-model resets while seed TCP waits nest Qt events.
    if (fCheckingSeeds)
    {
        updateSummary();
        return;
    }
    fRefreshing = true;

    if (peerModel)
        peerModel->refresh();

    updateSummary();

    fRefreshing = false;
}

void NetworkPage::refreshAll()
{
    refresh();
    // Manual button: allow seed probes even during IBD.
    runSeedProbes();
}

void NetworkPage::updateStats(int numConnections, int numBlocks)
{
    lblConnections->setText(QString::number(numConnections));
    lblBlocks->setText(QString::number(numBlocks));
}

// ---------------------------------------------------------------------------
// TCP seed connectivity check. Automatic path skips IBD; Refresh button forces.
// ---------------------------------------------------------------------------
void NetworkPage::checkSeedConnectivity()
{
    if (clientModel && clientModel->inInitialBlockDownload())
        return;
    runSeedProbes();
}

void NetworkPage::runSeedProbes()
{
    if (fCheckingSeeds)
        return;

    fCheckingSeeds = true;
    if (peerModel)
        peerModel->stopAutoRefresh();

    for (int i = 0; i < seedAddresses.size(); ++i)
    {
        QString addr = seedAddresses[i];
        int colon = addr.lastIndexOf(':');
        if (colon < 0) continue;
        QString host = addr.left(colon);
        quint16 port = addr.mid(colon + 1).toUShort();

        seedStatusLabels[i]->setText(statusDot(0));

        QTcpSocket probe;
        probe.connectToHost(host, port);
        bool ok = probe.waitForConnected(SEED_TCP_TIMEOUT_MS);
        if (ok) probe.disconnectFromHost();
        else probe.abort();

        seedStatusLabels[i]->setText(statusDot(ok ? 1 : 2));
        // Do NOT call QApplication::processEvents here: nested timer/model
        // resets during IBD caused ACCESS_VIOLATION (c0000005) on Windows.
    }

    if (peerModel)
        peerModel->startAutoRefresh();
    fCheckingSeeds = false;
}
