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
      timer(0)
{
    columns << tr("Address")
            << tr("User Agent")
            << tr("Version")
            << tr("Direction")
            << tr("Connected")
            << tr("Start Block")
            << tr("Ban Score");

    timer = new QTimer(this);
    connect(timer, SIGNAL(timeout()), this, SLOT(refresh()));
    timer->setInterval(MODEL_UPDATE_DELAY);
}

PeerTableModel::~PeerTableModel()
{
    // timer is a child of this — auto-deleted
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
    std::vector<CNodeStats> fresh;
    CopyPeerStats(fresh);

    beginResetModel();
    peers = fresh;
    endResetModel();
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
    case Address:
        return QString::fromStdString(s.addrName);

    case UserAgent:
        return QString::fromStdString(s.strSubVer);

    case Version:
        return QString::number(s.nVersion);

    case Direction:
        return s.fInbound ? tr("Inbound") : tr("Outbound");

    case Connected:
    {
        int64_t secs = GetTime() - s.nTimeConnected;
        if (secs < 60)
            return tr("%1 sec").arg(secs);
        if (secs < 3600)
            return tr("%1 min").arg(secs / 60);
        return tr("%1 h").arg(secs / 3600);
    }

    case StartHeight:
        return s.nStartingHeight;

    case BanScore:
        return s.nMisbehavior;
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
