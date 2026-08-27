#ifndef PEERTABLEMODEL_H
#define PEERTABLEMODEL_H

#include <QAbstractTableModel>
#include <QStringList>
#include <QTimer>
#include <vector>

#include "net.h"

class ClientModel;

/**
 * Qt table model for connected P2P peers.
 *
 * Columns:
 *   0  NodeId       – stable connection id
 *   1  Address      – Node/Service (IP:port)
 *   2  User Agent   – peer subver string
 *   3  Ping         – last measured round-trip (ms)
 */
class PeerTableModel : public QAbstractTableModel
{
    Q_OBJECT

public:
    enum ColumnIndex {
        NodeId      = 0,
        Address     = 1,
        UserAgent   = 2, // displayed as "Version" (strSubVer)
        Ping        = 3,
        NumColumns  = 4
    };

    explicit PeerTableModel(ClientModel *parent = 0);
    ~PeerTableModel();

    int rowCount(const QModelIndex &parent = QModelIndex()) const;
    int columnCount(const QModelIndex &parent = QModelIndex()) const;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const;
    QVariant headerData(int section, Qt::Orientation orientation,
                        int role = Qt::DisplayRole) const;
    Qt::ItemFlags flags(const QModelIndex &index) const;

    const CNodeStats *nodeStats(int row) const;
    /** Return row for node id, or -1 if not present. */
    int getRowByNodeId(int nodeid) const;

    /**
     * When true, refresh while IBD is in progress (Debug Network tab).
     * Default false: NetworkPage skips IBD refreshes to avoid Windows paint churn.
     */
    void setRefreshDuringIbd(bool enable);

    void startAutoRefresh();
    void stopAutoRefresh();

public slots:
    void refresh();

private:
    ClientModel             *clientModel;
    std::vector<CNodeStats>  peers;
    QTimer                  *timer;
    QStringList              columns;
    bool                     fRefreshing;
    bool                     fRefreshDuringIbd;
};

#endif // PEERTABLEMODEL_H
