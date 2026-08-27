#ifndef BANTABLEMODEL_H
#define BANTABLEMODEL_H

#include <QAbstractTableModel>
#include <QStringList>
#include <QTimer>
#include <vector>
#include <string>

#include "netbase.h"

class ClientModel;

struct CBannedNodeRow
{
    std::string addr;
    int64_t bannedUntil;
};

/**
 * Qt table model for currently banned peers (CNode::setBanned).
 *
 * Columns:
 *   0  Address     – banned IP
 *   1  Banned Until – unix time / formatted expiry
 */
class BanTableModel : public QAbstractTableModel
{
    Q_OBJECT

public:
    enum ColumnIndex {
        Address     = 0,
        BannedUntil = 1,
        NumColumns  = 2
    };

    explicit BanTableModel(ClientModel *parent = 0);
    ~BanTableModel();

    int rowCount(const QModelIndex &parent = QModelIndex()) const;
    int columnCount(const QModelIndex &parent = QModelIndex()) const;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const;
    QVariant headerData(int section, Qt::Orientation orientation,
                        int role = Qt::DisplayRole) const;
    Qt::ItemFlags flags(const QModelIndex &index) const;

    /** True when there is at least one active ban to show. */
    bool shouldShow() const;

    void startAutoRefresh();
    void stopAutoRefresh();

public slots:
    void refresh();

private:
    ClientModel                 *clientModel;
    std::vector<CBannedNodeRow>  bans;
    QTimer                      *timer;
    QStringList                  columns;
    bool                         fRefreshing;
};

#endif // BANTABLEMODEL_H
