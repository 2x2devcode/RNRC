#ifndef NETWORKPAGE_H
#define NETWORKPAGE_H

#include <QWidget>

class ClientModel;
class PeerTableModel;

QT_BEGIN_NAMESPACE
class QLabel;
class QTableView;
class QSortFilterProxyModel;
class QTimer;
class QPushButton;
class QHeaderView;
class QGroupBox;
class QAbstractItemModel;
QT_END_NAMESPACE

/**
 * NetworkPage — the "Network" tab of the RNRC wallet.
 *
 * Displays:
 *   • Summary statistics (connections, block height, last block time)
 *   • Hardcoded seed nodes with status derived from live peer connections
 *     (no blocking TCP probes on the GUI thread — those caused Windows
 *     ACCESS_VIOLATION / c0000005 during IBD)
 *   • Table of currently connected peers (auto-refreshed when not in IBD)
 *
 * Call setClientModel() once a ClientModel is available.
 */
class NetworkPage : public QWidget
{
    Q_OBJECT

public:
    explicit NetworkPage(QWidget *parent = 0);
    ~NetworkPage();

    /** Attach the client model (must be called before the page is shown). */
    void setClientModel(ClientModel *model);

public slots:
    /** Update peers table + summary (safe for connection-change signals). */
    void refresh();

    /** Same as refresh (kept for the Refresh button). */
    void refreshAll();

    /** Update the summary counters (connections / blocks). */
    void updateStats(int numConnections, int numBlocks);

    /** Summary + seed dots only — safe for high-frequency numBlocksChanged. */
    void updateSummary();

private:
    void buildSeedSection();
    void buildPeerSection();
    void buildSummarySection();
    /** Colour seed dots from currently connected peers (no network I/O). */
    void updateSeedStatusFromPeers();
    /** Return coloured HTML "●" indicator: green=ok, red=fail, grey=unknown. */
    static QString statusDot(int state); // 0=unknown, 1=connected, 2=not connected

    ClientModel    *clientModel;
    PeerTableModel *peerModel;
    QSortFilterProxyModel *proxyModel;
    bool            fRefreshing;

    // Summary labels
    QLabel *lblConnections;
    QLabel *lblBlocks;
    QLabel *lblLastBlock;

    // Seed rows — parallel arrays keep seed address and its status label
    QList<QString> seedAddresses;
    QList<QLabel*>  seedStatusLabels;

    // Peers table
    QTableView     *peersTable;

    // Refresh button
    QPushButton    *refreshButton;
};

#endif // NETWORKPAGE_H
