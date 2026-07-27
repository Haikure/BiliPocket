#pragma once

#include <QObject>
#include <QtGlobal>
#include <QString>
#include <QUrl>

class BiliController;

class BiliVideoModule : public QObject {
  Q_OBJECT
public:
  explicit BiliVideoModule(BiliController *controller);
  Q_INVOKABLE void reportCurrentVideoAsRecentViewIfNeeded();
  void refreshCurrentPlaybackProgress();
  Q_INVOKABLE void fetchVideoDetail(const QString &bvid);
  Q_INVOKABLE void preloadVideoDetail(const QString &bvid);
  Q_INVOKABLE void resolveVideoLink(const QString &link);
  Q_INVOKABLE void captureCurrentVideoDetail();
  Q_INVOKABLE bool restoreCachedVideoDetail(const QString &bvid);
  Q_INVOKABLE void dropCachedVideoDetail(const QString &bvid);
  Q_INVOKABLE QObject *videoPartModel();

signals:
  void videoLinkResolved(const QString &bvid);

private:
  void scheduleVideoDetailPreload(const QString &bvid, qint64 aid, qint64 cid);
  void resolveShortVideoLink(const QUrl &url, bool useGet);

  BiliController *m_controller;
  // 最近观看上报去重键
  QString m_lastRecentViewReportKey;
};
