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
 *   • Hardcoded seed nodes with live TCP connectivity status
 *   • Table of currently connected peers (auto-refreshed)
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
    /** Manually refresh peers table and seed statuses. */
    void refresh();

    /** Update the summary counters (connections / blocks). */
    void updateStats(int numConnections, int numBlocks);

private slots:
    void checkSeedConnectivity();

private:
    void buildSeedSection();
    void buildPeerSection();
    void buildSummarySection();
    /** Return coloured HTML "●" indicator: green=ok, red=fail, grey=unknown. */
    static QString statusDot(int state); // 0=unknown, 1=ok, 2=fail

    ClientModel    *clientModel;
    PeerTableModel *peerModel;
    QSortFilterProxyModel *proxyModel;

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

    QTimer         *seedCheckTimer;
};

#endif // NETWORKPAGE_H
