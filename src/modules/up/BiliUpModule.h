#pragma once

#include <QObject>
#include <QtGlobal>
#include <QString>

class BiliController;

class BiliUpModule : public QObject {
  Q_OBJECT
public:
  explicit BiliUpModule(BiliController *controller);
  Q_INVOKABLE void fetchUpInfo(qint64 mid);
  Q_INVOKABLE void fetchUpVideos(qint64 mid, int page = 1, int pageSize = 20);
  Q_INVOKABLE void fetchUpVideosAroundAid(qint64 mid, qint64 aid, int pageSize = 20);
  Q_INVOKABLE bool canFetchPreviousUpVideos() const;
  Q_INVOKABLE void fetchPreviousUpVideos();
  Q_INVOKABLE void fetchMoreUpVideos();
  Q_INVOKABLE void searchUpVideos(qint64 mid, const QString &keyword, int page = 1, int pageSize = 20);
  Q_INVOKABLE void searchMoreUpVideos();
  Q_INVOKABLE void clearUpSearch();
  Q_INVOKABLE void fetchUpSeasons(qint64 mid);
  Q_INVOKABLE void fetchMoreUpSeasons();
  Q_INVOKABLE QObject *upSearchVideoModel();
  Q_INVOKABLE void selectUpSeason(qint64 seasonId, const QString &name = QString(), bool isSeries = false, int total = 0);
  Q_INVOKABLE void selectUpDynamic();
  Q_INVOKABLE void toggleUpFollow();
  Q_INVOKABLE void playVideoPart(int index);
  Q_INVOKABLE void restartGoServer();
  Q_INVOKABLE void downloadVideoToDisk(int quality);
  Q_INVOKABLE QObject *upVideoModel();
  Q_INVOKABLE QObject *upSeasonModel();

  int lastWatchedRank() const { return m_upLastWatchedRank; }

private:
  void fetchUpSeasonsPage(qint64 mid, int page);

  BiliController *m_controller;
  qint64 m_upSearchMid = 0;
  QString m_upSearchKeyword;
  int m_upSearchPage = 1;
  int m_upSearchPageSize = 20;
  // 合集/系列分页状态（页码在请求成功后才推进）
  int m_upSeasonListPage = 1;
  bool m_upSeasonListHasMore = true;
  // UP 主投稿列表分页/游标状态
  int m_upVideoPage = 1;
  bool m_upVideoHasMore = true;
  // APP 游标翻页：记录下一页游标（max/next）。用于修复“加载更多只拿到第一页”和新稿件插入导致的丢失。
  qint64 m_upVideoCursorNext = 0;
  qint64 m_upVideoCursorPrev = 0;
  bool m_upVideoHasPrevious = false;
  // “上次看到”标记，QML 经 controller.upLastWatchedRank 读取
  int m_upLastWatchedRank = 0;
  bool m_upFollowLoading = false;
};
