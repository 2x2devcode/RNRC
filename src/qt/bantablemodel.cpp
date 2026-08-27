#include "bantablemodel.h"
#include "clientmodel.h"
#include "guiconstants.h"
#include "guiutil.h"

#include "net.h"
#include "sync.h"
#include "util.h"

#include <QDateTime>
#include <QTimer>
#include <map>

BanTableModel::BanTableModel(ClientModel *parent)
    : QAbstractTableModel(parent),
      clientModel(parent),
      timer(0),
      fRefreshing(false)
{
    columns << tr("Address")
            << tr("Banned Until");

    timer = new QTimer(this);
    connect(timer, SIGNAL(timeout()), this, SLOT(refresh()));
    timer->setInterval(MODEL_UPDATE_DELAY);
}

BanTableModel::~BanTableModel()
{
}

void BanTableModel::startAutoRefresh()
{
    refresh();
    timer->start();
}

void BanTableModel::stopAutoRefresh()
{
    timer->stop();
}

void BanTableModel::refresh()
{
    if (fRefreshing)
        return;
    fRefreshing = true;

    std::map<CNetAddr, int64_t> banMap;
    CNode::GetBanned(banMap);

    std::vector<CBannedNodeRow> fresh;
    fresh.reserve(banMap.size());
    const int64_t now = GetTime();
    for (std::map<CNetAddr, int64_t>::const_iterator it = banMap.begin();
         it != banMap.end(); ++it)
    {
        if (it->second <= now)
            continue; // expired
        CBannedNodeRow row;
        row.addr = it->first.ToString();
        row.bannedUntil = it->second;
        fresh.push_back(row);
    }

    beginResetModel();
    bans = fresh;
    endResetModel();

    fRefreshing = false;
}

int BanTableModel::rowCount(const QModelIndex &) const
{
    return (int)bans.size();
}

int BanTableModel::columnCount(const QModelIndex &) const
{
    return NumColumns;
}

QVariant BanTableModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 ||
        index.row() >= (int)bans.size())
        return QVariant();

    if (role != Qt::DisplayRole && role != Qt::ToolTipRole)
        return QVariant();

    const CBannedNodeRow &r = bans[index.row()];
    switch (index.column())
    {
    case Address:
        return QString::fromStdString(r.addr);
    case BannedUntil:
        return QDateTime::fromTime_t((uint)r.bannedUntil).toString(Qt::DefaultLocaleShortDate);
    }
    return QVariant();
}

QVariant BanTableModel::headerData(int section, Qt::Orientation orientation,
                                   int role) const
{
    if (orientation != Qt::Horizontal || role != Qt::DisplayRole)
        return QVariant();
    if (section < 0 || section >= columns.size())
        return QVariant();
    return columns[section];
}

Qt::ItemFlags BanTableModel::flags(const QModelIndex &index) const
{
    if (!index.isValid())
        return Qt::NoItemFlags;
    return Qt::ItemIsSelectable | Qt::ItemIsEnabled;
}

bool BanTableModel::shouldShow() const
{
    return !bans.empty();
}
