#pragma once

#include <QObject>
#include <QtGlobal>

class BiliController;

class BiliSeasonModule : public QObject {
  Q_OBJECT
public:
  explicit BiliSeasonModule(BiliController *controller);

  Q_INVOKABLE void fetchRelatedVideos();
  Q_INVOKABLE void fetchUpSeasonVideos(int page = 1, int pageSize = 30);
  Q_INVOKABLE void fetchUpSeriesVideos(int page = 1, int pageSize = 30);
  Q_INVOKABLE void fetchMoreUpSeasonVideos();
  Q_INVOKABLE void fetchSeasonVideos(qint64 mid, qint64 seasonId, int page = 1,
                                     int pageSize = 30, bool oldestFirst = false);
  Q_INVOKABLE void fetchMoreSeasonVideos();
  Q_INVOKABLE QObject *seasonVideoModel();
  Q_INVOKABLE QObject *relatedVideoModel();

private:
  BiliController *m_controller;
};
