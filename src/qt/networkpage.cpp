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
#include <QSortFilterProxyModel>
#include <QSplitter>
#include <QTableView>
#include <QVBoxLayout>
#include <QFont>

#include <set>
#include <string>

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

// ---------------------------------------------------------------------------

NetworkPage::NetworkPage(QWidget *parent)
    : QWidget(parent),
      clientModel(0),
      peerModel(0),
      proxyModel(0),
      fRefreshing(false),
      lblConnections(0),
      lblBlocks(0),
      lblLastBlock(0),
      peersTable(0),
      refreshButton(0)
{
    QVBoxLayout *mainLayout = new QVBoxLayout(this);
    mainLayout->setContentsMargins(8, 8, 8, 8);
    mainLayout->setSpacing(8);

    QLabel *title = new QLabel(tr("<b>Network</b>"), this);
    QFont tf = title->font();
    tf.setPointSize(tf.pointSize() + 2);
    title->setFont(tf);
    mainLayout->addWidget(title);

    refreshButton = new QPushButton(tr("Refresh"), this);
    refreshButton->setMaximumWidth(120);
    connect(refreshButton, SIGNAL(clicked()), this, SLOT(refreshAll()));

    QSplitter *splitter = new QSplitter(Qt::Horizontal, this);

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

    QHBoxLayout *bottomBar = new QHBoxLayout();
    bottomBar->addStretch();
    bottomBar->addWidget(refreshButton);
    mainLayout->addLayout(bottomBar);
}

NetworkPage::~NetworkPage()
{
}

void NetworkPage::setClientModel(ClientModel *model)
{
    clientModel = model;
    if (!model)
        return;

    peerModel = new PeerTableModel(model);
    proxyModel = new QSortFilterProxyModel(this);
    proxyModel->setSourceModel(peerModel);
    proxyModel->setSortCaseSensitivity(Qt::CaseInsensitive);
    peersTable->setModel(proxyModel);
    peersTable->sortByColumn(PeerTableModel::Address, Qt::AscendingOrder);
    peersTable->horizontalHeader()->setResizeMode(PeerTableModel::NodeId,     QHeaderView::ResizeToContents);
    peersTable->horizontalHeader()->setResizeMode(PeerTableModel::Address,   QHeaderView::Stretch);
    peersTable->horizontalHeader()->setResizeMode(PeerTableModel::UserAgent, QHeaderView::ResizeToContents);
    peersTable->horizontalHeader()->setResizeMode(PeerTableModel::Ping,      QHeaderView::ResizeToContents);

    // Connections: may refresh peer rows (skipped during IBD).
    // Blocks: labels + seed dots only — never reset the peer model.
    connect(model, SIGNAL(numConnectionsChanged(int)), this, SLOT(refresh()));
    connect(model, SIGNAL(numBlocksChanged(int,int)), this, SLOT(updateSummary()));

    peerModel->startAutoRefresh();
    refresh();
}

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
        QLabel *dot = new QLabel(statusDot(0), this);
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

QString NetworkPage::statusDot(int state)
{
    QString color;
    switch (state) {
    case 1:  color = "#27ae60"; break;  // green — connected
    case 2:  color = "#e74c3c"; break;  // red — not among peers
    default: color = "#95a5a6"; break;  // grey — unknown
    }
    return QString("<font color=\"%1\">\xe2\x97\x8f</font>").arg(color);
}

void NetworkPage::updateSeedStatusFromPeers()
{
    std::set<std::string> connected;
    {
        LOCK(cs_vNodes);
        BOOST_FOREACH(CNode* pnode, vNodes)
        {
            if (!pnode)
                continue;
            connected.insert(pnode->addr.ToStringIPPort());
            connected.insert(pnode->addrName);
        }
    }

    for (int i = 0; i < seedAddresses.size(); ++i)
    {
        const std::string seed = seedAddresses[i].toStdString();
        const bool ok = connected.count(seed) > 0;
        seedStatusLabels[i]->setText(statusDot(ok ? 1 : 2));
    }
}

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
    updateSeedStatusFromPeers();
}

void NetworkPage::refresh()
{
    if (fRefreshing)
        return;
    fRefreshing = true;

    // During IBD, avoid peer-table beginResetModel (high churn / painting races
    // on Windows). Summary + seed dots are enough.
    const bool inIbd = clientModel && clientModel->inInitialBlockDownload();
    if (peerModel && !inIbd)
        peerModel->refresh();

    updateSummary();

    fRefreshing = false;
}

void NetworkPage::refreshAll()
{
    refresh();
}

void NetworkPage::updateStats(int numConnections, int numBlocks)
{
    lblConnections->setText(QString::number(numConnections));
    lblBlocks->setText(QString::number(numBlocks));
}
