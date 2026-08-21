#ifndef PEERTABLEMODEL_H
#define PEERTABLEMODEL_H

#include <QAbstractTableModel>
#include <QStringList>
#include <QTimer>
#include <vector>

#include "net.h"

class ClientModel;

/**
 * Qt table model that exposes the list of currently connected P2P peers.
 * Refreshed automatically by an internal timer (MODEL_UPDATE_DELAY ms).
 *
 * Columns:
 *   0  Address     – IP:port of the peer
 *   1  User Agent  – client software string reported by the peer
 *   2  Version     – protocol version number
 *   3  Direction   – "Inbound" or "Outbound"
 *   4  Connected   – duration since the connection was established
 *   5  Start Block – block height at which the peer joined
 *   6  Ban Score   – current misbehaviour penalty score
 */
class PeerTableModel : public QAbstractTableModel
{
    Q_OBJECT

public:
    enum ColumnIndex {
        Address     = 0,
        UserAgent   = 1,
        Version     = 2,
        Direction   = 3,
        Connected   = 4,
        StartHeight = 5,
        BanScore    = 6,
        NumColumns  = 7
    };

    explicit PeerTableModel(ClientModel *parent = 0);
    ~PeerTableModel();

    // QAbstractTableModel interface
    int rowCount(const QModelIndex &parent = QModelIndex()) const;
    int columnCount(const QModelIndex &parent = QModelIndex()) const;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const;
    QVariant headerData(int section, Qt::Orientation orientation,
                        int role = Qt::DisplayRole) const;
    Qt::ItemFlags flags(const QModelIndex &index) const;

    /** Return the CNodeStats for the peer at the given row, or NULL. */
    const CNodeStats *nodeStats(int row) const;

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
};

#endif // PEERTABLEMODEL_H
