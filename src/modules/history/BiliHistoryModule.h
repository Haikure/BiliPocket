#pragma once

#include <QObject>
#include <QString>
#include <QtGlobal>

class BiliController;

class BiliHistoryModule : public QObject {
  Q_OBJECT
public:
  explicit BiliHistoryModule(BiliController *controller);

  Q_INVOKABLE void fetchRecentHistory();
  Q_INVOKABLE void fetchMoreRecentHistory();
  Q_INVOKABLE void searchHistory(const QString &keyword, int page = 1);
  Q_INVOKABLE void searchMoreHistory();
  Q_INVOKABLE void clearHistorySearch();
  Q_INVOKABLE void deleteRecentHistoryItem(int row, const QString &business, qint64 kid);
  Q_INVOKABLE void fetchWatchLater(int page = 1, int pageSize = 20);
  Q_INVOKABLE void fetchMoreWatchLater();
  Q_INVOKABLE void deleteWatchLaterItem(int row, qint64 aid);
  Q_INVOKABLE void addToWatchLater();
  Q_INVOKABLE QObject *recentHistoryModel();
  Q_INVOKABLE QObject *watchLaterModel();

private:
  BiliController *m_controller;
  qint64 m_recentHistoryMax = 0;
  qint64 m_recentHistoryViewAt = 0;
  QString m_historySearchKeyword;
  int m_historySearchPage = 1;
  bool m_historySearchHasMore = true;
  int m_watchLaterPage = 1;
  bool m_watchLaterHasMore = true;
};
