#include "peertablemodel.h"
#include "clientmodel.h"
#include "guiconstants.h"
#include "guiutil.h"

#include "net.h"
#include "sync.h"

#include <QDateTime>
#include <QTimer>

static void CopyPeerStats(std::vector<CNodeStats> &out)
{
    LOCK(cs_vNodes);
    out.clear();
    out.reserve(vNodes.size());
    BOOST_FOREACH(CNode *pnode, vNodes)
    {
        CNodeStats s;
        pnode->copyStats(s);
        out.push_back(s);
    }
}

PeerTableModel::PeerTableModel(ClientModel *parent)
    : QAbstractTableModel(parent),
      clientModel(parent),
      timer(0),
      fRefreshing(false),
      fRefreshDuringIbd(false)
{
    columns << tr("NodeId")
            << tr("Node/Service")
            << tr("Version")
            << tr("Ping Time");

    timer = new QTimer(this);
    connect(timer, SIGNAL(timeout()), this, SLOT(refresh()));
    timer->setInterval(MODEL_UPDATE_DELAY);
}

PeerTableModel::~PeerTableModel()
{
}

void PeerTableModel::setRefreshDuringIbd(bool enable)
{
    fRefreshDuringIbd = enable;
}

void PeerTableModel::startAutoRefresh()
{
    refresh();
    timer->start();
}

void PeerTableModel::stopAutoRefresh()
{
    timer->stop();
}

void PeerTableModel::refresh()
{
    if (fRefreshing)
        return;
    // Skip model resets during IBD unless the Debug Network tab opted in —
    // high-frequency beginResetModel painted poorly on Windows NetworkPage.
    if (!fRefreshDuringIbd && clientModel && clientModel->inInitialBlockDownload())
        return;
    fRefreshing = true;

    std::vector<CNodeStats> fresh;
    CopyPeerStats(fresh);

    beginResetModel();
    peers = fresh;
    endResetModel();

    fRefreshing = false;
}

int PeerTableModel::rowCount(const QModelIndex &) const
{
    return (int)peers.size();
}

int PeerTableModel::columnCount(const QModelIndex &) const
{
    return NumColumns;
}

QVariant PeerTableModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 ||
        index.row() >= (int)peers.size())
        return QVariant();

    if (role != Qt::DisplayRole && role != Qt::ToolTipRole)
        return QVariant();

    const CNodeStats &s = peers[index.row()];

    switch (index.column())
    {
    case NodeId:
        return s.nodeid;

    case Address:
        return QString::fromStdString(s.addrName);

    case UserAgent:
        return QString::fromStdString(s.strSubVer);

    case Ping:
        if (s.dPingTime < 0.0)
            return tr("N/A");
        // Show milliseconds for readability
        return tr("%1 ms").arg(QString::number(s.dPingTime * 1000.0, 'f', 1));
    }
    return QVariant();
}

QVariant PeerTableModel::headerData(int section, Qt::Orientation orientation,
                                    int role) const
{
    if (orientation != Qt::Horizontal || role != Qt::DisplayRole)
        return QVariant();
    if (section < 0 || section >= columns.size())
        return QVariant();
    return columns[section];
}

Qt::ItemFlags PeerTableModel::flags(const QModelIndex &index) const
{
    if (!index.isValid())
        return Qt::NoItemFlags;
    return Qt::ItemIsSelectable | Qt::ItemIsEnabled;
}

const CNodeStats *PeerTableModel::nodeStats(int row) const
{
    if (row < 0 || row >= (int)peers.size())
        return NULL;
    return &peers[row];
}

int PeerTableModel::getRowByNodeId(int nodeid) const
{
    for (int i = 0; i < (int)peers.size(); ++i)
    {
        if (peers[i].nodeid == nodeid)
            return i;
    }
    return -1;
}
