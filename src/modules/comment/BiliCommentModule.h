#pragma once

#include <QObject>
#include <QString>
#include <QtGlobal>
#include <QSet>

class BiliController;

class BiliCommentModule : public QObject {
  Q_OBJECT
  Q_PROPERTY(bool replyHasMore READ replyHasMore NOTIFY replyHasMoreChanged)
  Q_PROPERTY(bool commentsReady READ commentsReady NOTIFY commentsReadyChanged)
public:
  explicit BiliCommentModule(BiliController *controller);
  bool replyHasMore() const { return m_commentReplyHasMore; }
  bool commentsReady() const;
  Q_INVOKABLE bool commentsReadyForContext(const QString &contextKey) const;
  Q_INVOKABLE void fetchComments(int page = 1, bool silent = false);
  Q_INVOKABLE void fetchCommentsForContext(const QString &oid, int type, const QString &contextKey,
                                           int page = 1, bool silent = false);
  Q_INVOKABLE void fetchCommentReplies(qint64 rootRpid);
  Q_INVOKABLE void fetchCommentRepliesForContext(const QString &oid, int type,
                                                 const QString &contextKey,
                                                 qint64 rootRpid);
  Q_INVOKABLE void fetchMoreCommentReplies();
  Q_INVOKABLE void fetchMoreCommentRepliesForContext(const QString &oid, int type,
                                                     const QString &contextKey);
  Q_INVOKABLE void fetchMoreComments();
  Q_INVOKABLE void fetchMoreCommentsForContext(const QString &oid, int type,
                                               const QString &contextKey);
  Q_INVOKABLE QObject *commentModel();
  Q_INVOKABLE QObject *commentReplyModel();
  Q_INVOKABLE void toggleCommentLike(const QString &oid, int type, qint64 rpid,
                                     bool currentlyLiked);
  void resetReplyState();
  void resetForVideoChange();

signals:
  void replyHasMoreChanged();
  void commentsReadyChanged();
  void commentLikeChanged(qint64 rpid, bool liked, qint64 likes);

private:
  BiliController *m_controller;
  int m_commentPage = 1;
  QString m_commentBvid;
  QString m_commentOid;
  int m_commentType = 1;
  QString m_commentNextOffset;
  bool m_commentFirstPageLoaded = false;
  bool m_commentHasMore = true;
  int m_commentReplyPage = 1;
  bool m_commentReplyHasMore = false;
  qint64 m_currentCommentRootRpid = 0;
  QString m_replyOid;
  int m_replyType = 1;
  QString m_replyContextKey;
  QSet<qint64> m_likeRequests;
};
