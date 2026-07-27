#include "modules/comment/BiliCommentModule.h"
#include "BiliAsyncUtils.hpp"
#include "BiliController.h"
#include "BiliJsonUtils.h"
#include "BiliListFetch.hpp"
#include "BiliModels.h"
#include "BiliNetwork.h"
#include "modules/history/BiliHistoryModule.h"
#include "modules/login/BiliLoginModule.h"
#include "modules/season/BiliSeasonModule.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QProcess>
#include <QRegExp>
#include <QSet>
#include <QSettings>
#include <QStandardPaths>
#include <QStringListModel>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>
#include <QtGlobal>
#include <algorithm>
#include <functional>

namespace {

struct ParsedComments {
  int page = 1;
  int total = 0;
  QVector<CommentItem> items;
  QString nextOffset;
  bool hasMore = false;
};

struct ParsedCommentReplies {
  int page = 1;
  int total = 0;
  QVector<CommentReplyItem> items;
  bool hasMore = false;
};

ParsedComments parseCommentsPayload(const QJsonObject &data, int page) {
  ParsedComments result;
  result.page = page;

  QJsonObject pageObj = data.value("page").toObject();
  result.total = pageObj.value("count").toInt();
  QJsonObject cursorObj = data.value("cursor").toObject();
  QJsonObject paginationReply = cursorObj.value("pagination_reply").toObject();
  result.nextOffset = paginationReply.value("next_offset").toString();
  if (result.nextOffset.isEmpty()) {
    result.nextOffset = cursorObj.value("next_offset").toString();
  }
  if (result.nextOffset.isEmpty()) {
    result.nextOffset = cursorObj.value("offset").toString();
  }

  QJsonArray replies = data.value("replies").toArray();
  QSet<qint64> seenRpids;
  seenRpids.reserve(replies.size() + 6);

  auto hasComment = [&seenRpids](qint64 rpid) {
    return rpid > 0 && seenRpids.contains(rpid);
  };
  auto markComment = [&seenRpids](qint64 rpid) {
    if (rpid > 0)
      seenRpids.insert(rpid);
  };
  auto appendTopComment = [&result, &hasComment,
                           &markComment](const QJsonObject &obj) {
    if (obj.isEmpty())
      return;
    CommentItem topComment = CommentListModel::parseCommentItem(obj);
    if (topComment.rpid <= 0 || hasComment(topComment.rpid))
      return;
    topComment.isTop = true;
    markComment(topComment.rpid);
    result.items.append(topComment);
  };

  if (page == 1) {
    appendTopComment(data.value("upper").toObject().value("top").toObject());

    QJsonObject topObj = data.value("top").toObject();
    const QStringList topKeys = {"upper", "admin", "vote"};
    for (const QString &key : topKeys) {
      appendTopComment(topObj.value(key).toObject());
    }

    QJsonArray topReplies = data.value("top_replies").toArray();
    for (const QJsonValue &v : topReplies) {
      if (v.isObject())
        appendTopComment(v.toObject());
    }
  }

  result.items.reserve(result.items.size() + replies.size());
  for (const QJsonValue &v : replies) {
    if (!v.isObject())
      continue;
    CommentItem comment = CommentListModel::parseCommentItem(v.toObject());
    if (!hasComment(comment.rpid)) {
      markComment(comment.rpid);
      result.items.append(comment);
    }
  }

  const int num = pageObj.value("num").toInt(page);
  const int size = pageObj.value("size").toInt(20);
  result.hasMore = !result.nextOffset.isEmpty() ||
      ((result.total > 0) ? (num * size < result.total) : (result.items.size() >= size));
  return result;
}

ParsedCommentReplies parseCommentRepliesPayload(const QJsonObject &data,
                                                int page) {
  ParsedCommentReplies result;
  result.page = page;

  QJsonArray replies = data.value("replies").toArray();
  result.items.reserve(replies.size());
  for (const QJsonValue &v : replies) {
    if (v.isObject()) {
      result.items.append(
          CommentReplyListModel::parseCommentReplyItem(v.toObject()));
    }
  }

  // B 站 /x/v2/reply/reply 的 page 字段偶发缺省/字符串化，需多字段兜底。
  QJsonObject pageObj = data.value("page").toObject();
  const int count = pageObj.value("count").toVariant().toInt();
  const int acount = pageObj.value("acount").toVariant().toInt();
  const int total = count > 0 ? count : acount;
  int num = pageObj.value("num").toVariant().toInt();
  if (num <= 0)
    num = page;
  int size = pageObj.value("size").toVariant().toInt();
  if (size <= 0)
    size = 20;

  result.total = total > 0 ? total : 0;
  if (result.total > 0) {
    // 优先用总数判断；本页为空时不再继续翻页。
    result.hasMore = (num * size < result.total) && !result.items.isEmpty();
  } else {
    // 无总数时：本页满页则认为还有更多。
    result.hasMore = result.items.size() >= size;
  }
  return result;
}

} // namespace

BiliCommentModule::BiliCommentModule(BiliController *controller)
    : QObject(controller), m_controller(controller) {}

bool BiliCommentModule::commentsReady() const {
  return m_controller && m_commentFirstPageLoaded &&
         m_commentBvid == m_controller->videoBvid() &&
         m_commentOid == QString::number(m_controller->videoAid()) &&
         m_commentType == 1;
}

bool BiliCommentModule::commentsReadyForContext(const QString &contextKey) const {
  return m_commentFirstPageLoaded && !contextKey.isEmpty() &&
         m_commentBvid == contextKey;
}

QObject *BiliCommentModule::commentModel() { return m_controller->commentListModel(); }
QObject *BiliCommentModule::commentReplyModel() { return m_controller->commentReplyListModel(); }

void BiliCommentModule::toggleCommentLike(const QString &oid, int type, qint64 rpid,
                                          bool currentlyLiked) {
  if (!m_controller || !m_controller->loggedIn()) {
    if (m_controller) emit m_controller->toastMessage("请先登录后再点赞");
    return;
  }
  const QString requestOid = oid.trimmed();
  if (requestOid.isEmpty() || requestOid == "0" || type <= 0 || rpid <= 0) {
    emit m_controller->toastMessage("评论信息不完整");
    return;
  }
  if (m_likeRequests.contains(rpid)) return;
  m_likeRequests.insert(rpid);

  QMap<QString, QString> params;
  params["oid"] = requestOid;
  params["type"] = QString::number(type);
  params["rpid"] = QString::number(rpid);
  params["action"] = currentlyLiked ? "0" : "1";

  QPointer<BiliController> self(m_controller);
  const bool targetLiked = !currentlyLiked;
  m_controller->apiGet(
      "/comment/like/toggle", params,
      [this, self, rpid, targetLiked](const QJsonObject &) {
        m_likeRequests.remove(rpid);
        if (!self) return;
        qint64 likes = 0;
        bool found = false;
        if (self->commentListModel()->setLikeState(rpid, targetLiked)) {
          found = true;
          const QAbstractItemModel *model = self->commentListModel();
          for (int row = 0; row < model->rowCount(); ++row) {
            const QModelIndex idx = model->index(row, 0);
            if (model->data(idx, CommentListModel::RpidRole).toLongLong() == rpid) {
              likes = model->data(idx, CommentListModel::LikesRole).toLongLong();
              break;
            }
          }
        }
        if (self->commentReplyListModel()->setLikeState(rpid, targetLiked)) {
          found = true;
          const QAbstractItemModel *model = self->commentReplyListModel();
          for (int row = 0; row < model->rowCount(); ++row) {
            const QModelIndex idx = model->index(row, 0);
            if (model->data(idx, CommentReplyListModel::RpidRole).toLongLong() == rpid) {
              likes = model->data(idx, CommentReplyListModel::LikesRole).toLongLong();
              break;
            }
          }
        }
        if (found) emit commentLikeChanged(rpid, targetLiked, likes);
        emit self->toastMessage(targetLiked ? "已点赞" : "已取消点赞");
      },
      [this, self, rpid](int, const QString &msg) {
        m_likeRequests.remove(rpid);
        if (self) emit self->toastMessage(QString("评论点赞失败：%1").arg(msg));
      });
}

void BiliCommentModule::resetReplyState() {
  if (!m_commentReplyHasMore) return;
  m_commentReplyHasMore = false;
  emit replyHasMoreChanged();
}

void BiliCommentModule::resetForVideoChange() {
  const bool wasReady = commentsReady();
  const bool replyHadMore = m_commentReplyHasMore;

  m_commentPage = 1;
  m_commentBvid.clear();
  m_commentOid.clear();
  m_commentType = 1;
  m_commentNextOffset.clear();
  m_commentFirstPageLoaded = false;
  m_commentHasMore = true;
  m_commentReplyPage = 1;
  m_commentReplyHasMore = false;
  m_currentCommentRootRpid = 0;
  m_replyOid.clear();
  m_replyType = 1;
  m_replyContextKey.clear();

  if (m_controller) {
    if (m_controller->commentListModel()) {
      m_controller->commentListModel()->setLoading(false);
      m_controller->commentListModel()->clear();
    }
    if (m_controller->commentReplyListModel()) {
      m_controller->commentReplyListModel()->setLoading(false);
      m_controller->commentReplyListModel()->clear();
    }
  }

  if (wasReady)
    emit commentsReadyChanged();
  if (replyHadMore)
    emit replyHasMoreChanged();
}

// ====== API: 评论 ======

void BiliCommentModule::fetchComments(int page, bool silent) {
  const QString currentBvid = m_controller->videoBvid();
  if (currentBvid.isEmpty()) {
    if (!silent) emit m_controller->toastMessage("请先打开一个视频");
    return;
  }
  if (m_controller->commentListModel()->loading()) {
    if (m_commentBvid == currentBvid) return;
    m_controller->commentListModel()->setLoading(false);
  }
  if (m_controller->videoAid() <= 0) {
    if (!silent) emit m_controller->toastMessage("视频信息不完整");
    return;
  }

  fetchCommentsForContext(QString::number(m_controller->videoAid()), 1, currentBvid,
                          page, silent);
}

void BiliCommentModule::fetchCommentsForContext(const QString &oid, int type,
                                                const QString &contextKey,
                                                int page, bool silent) {
  if (!m_controller) return;
  const QString requestOidString = oid.trimmed();
  const QString requestContextKey =
      contextKey.isEmpty() ? QString("%1:%2").arg(type).arg(requestOidString) : contextKey;
  if (requestOidString.isEmpty() || requestOidString == "0" ||
      type <= 0 || requestContextKey.isEmpty()) {
    if (!silent) emit m_controller->toastMessage("评论信息不完整");
    return;
  }
  page = qBound(1, page, 1000);
  if (page == 1 && m_commentBvid == requestContextKey &&
      m_commentOid == requestOidString && m_commentType == type && m_commentFirstPageLoaded) {
    return;
  }
  if (m_controller->commentListModel()->loading()) {
    if (m_commentBvid == requestContextKey && m_commentOid == requestOidString &&
        m_commentType == type) {
      return;
    }
    m_controller->commentListModel()->setLoading(false);
  }

  m_commentPage = page;
  if (page == 1) {
    const bool wasReady = m_commentFirstPageLoaded;
    m_commentBvid = requestContextKey;
    m_commentOid = requestOidString;
    m_commentType = type;
    m_commentFirstPageLoaded = false;
    if (wasReady) emit commentsReadyChanged();
    m_commentNextOffset.clear();
    m_commentHasMore = true;
    m_controller->commentListModel()->clear();
    if (m_controller->commentReplyListModel()) {
      m_controller->commentReplyListModel()->clear();
    }
    m_commentReplyPage = 1;
    m_commentReplyHasMore = false;
    m_currentCommentRootRpid = 0;
    m_replyOid.clear();
    m_replyType = 1;
    m_replyContextKey.clear();
    emit replyHasMoreChanged();
  }
  m_controller->commentListModel()->setLoading(true);

  QMap<QString, QString> params;
  params["oid"] = requestOidString;
  params["type"] = QString::number(type);
  params["sort"] = "2";
  params["mode"] = "4";
  params["pn"] = QString::number(page);
  params["ps"] = "20";
  if (page > 1 && !m_commentNextOffset.isEmpty()) {
    params["offset"] = m_commentNextOffset;
  }

  const int requestPage = page;
  const QString requestKey = requestContextKey;
  const QString requestOid = requestOidString;
  const int requestType = type;
  BiliListFetch::fetchParsed(
      m_controller, BiliListFetch::Via::Api, "/video/comments", params,
      BiliListFetch::acceptAlways,
      [requestPage](const QJsonObject &data) {
        return parseCommentsPayload(data, requestPage);
      },
      [this, requestKey, requestOid, requestType](BiliController *self,
                                                  ParsedComments result) {
        if (m_commentPage != result.page || m_commentBvid != requestKey ||
            m_commentOid != requestOid || m_commentType != requestType)
          return;
        if (result.page == 1) {
          m_commentFirstPageLoaded = true;
          emit commentsReadyChanged();
        }
        m_commentNextOffset = result.nextOffset;
        m_commentHasMore = result.hasMore;
        self->commentListModel()->setTotalCount(result.total);
        self->commentListModel()->appendItems(result.items);
        self->commentListModel()->setLoading(false);

        if (result.items.isEmpty() && result.page == 1) {
          self->commentListModel()->setErrorMessage("暂无评论");
        }
      },
      [this, requestKey, requestOid, requestType, requestPage,
       silent](BiliController *self, int code, const QString &msg) {
        if (m_commentBvid != requestKey ||
            m_commentOid != requestOid || m_commentType != requestType)
          return;
        if (m_commentPage == requestPage && m_commentPage > 1) {
          m_commentPage--;
        }
        self->commentListModel()->setLoading(false);
        if (code == -404 || msg == "啥都木有") {
          m_commentFirstPageLoaded = true;
          emit commentsReadyChanged();
          self->commentListModel()->setErrorMessage("暂无评论");
        } else {
          self->commentListModel()->setErrorMessage(msg);
          if (!silent) emit self->toastMessage(QString("评论加载失败：%1").arg(msg));
        }
      });
}

void BiliCommentModule::fetchCommentReplies(qint64 rootRpid) {
  const QString requestBvid = m_controller->videoBvid();
  const qint64 requestAid = m_controller->videoAid();
  if (requestBvid.isEmpty() || requestAid <= 0 || rootRpid <= 0) {
    emit m_controller->toastMessage("评论信息不完整");
    return;
  }
  fetchCommentRepliesForContext(QString::number(requestAid), 1, requestBvid, rootRpid);
}

void BiliCommentModule::fetchCommentRepliesForContext(const QString &oid, int type,
                                                      const QString &contextKey,
                                                      qint64 rootRpid) {
  if (!m_controller) return;
  const QString requestOidString = oid.trimmed();
  const QString requestContextKey =
      contextKey.isEmpty() ? QString("%1:%2").arg(type).arg(requestOidString) : contextKey;
  if (requestOidString.isEmpty() || requestOidString == "0" ||
      type <= 0 || requestContextKey.isEmpty() || rootRpid <= 0) {
    emit m_controller->toastMessage("评论信息不完整");
    return;
  }
  if (m_controller->commentReplyListModel()->loading())
    return;

  m_currentCommentRootRpid = rootRpid;
  m_replyOid = requestOidString;
  m_replyType = type;
  m_replyContextKey = requestContextKey;
  m_commentReplyPage = 1;
  m_commentReplyHasMore = false;
  emit replyHasMoreChanged();

  m_controller->commentReplyListModel()->clear();
  m_controller->commentReplyListModel()->setLoading(true);

  QMap<QString, QString> params;
  params["oid"] = requestOidString;
  params["type"] = QString::number(type);
  params["root"] = QString::number(rootRpid);
  params["ps"] = "20";
  params["pn"] = QString::number(m_commentReplyPage);

  const qint64 requestRootRpid = rootRpid;
  const int requestPage = m_commentReplyPage;
  const QString requestOid = requestOidString;
  const int requestType = type;
  const QString requestKey = requestContextKey;
  BiliListFetch::fetchParsed(
      m_controller, BiliListFetch::Via::Api, "/video/comments/replies", params,
      [this, requestOid, requestType, requestKey](BiliController *) {
        return m_replyOid == requestOid && m_replyType == requestType &&
               m_replyContextKey == requestKey;
      },
      [requestPage](const QJsonObject &data) {
        return parseCommentRepliesPayload(data, requestPage);
      },
      [this, requestRootRpid, requestOid, requestType,
       requestKey](BiliController *self, ParsedCommentReplies result) {
        if (m_replyOid != requestOid || m_replyType != requestType ||
            m_replyContextKey != requestKey || m_currentCommentRootRpid != requestRootRpid ||
            m_commentReplyPage != result.page)
          return;

        m_commentReplyHasMore = result.hasMore;
        emit replyHasMoreChanged();

        if (result.total > 0) {
          self->commentReplyListModel()->setTotalCount(result.total);
        } else if (result.items.size() > self->commentReplyListModel()->totalCount()) {
          self->commentReplyListModel()->setTotalCount(result.items.size());
        }
        self->commentReplyListModel()->setItems(result.items);
        self->commentReplyListModel()->setLoading(false);
        if (result.items.isEmpty()) {
          self->commentReplyListModel()->setErrorMessage("暂无回复");
        }
      },
      [this, requestOid, requestType, requestKey](BiliController *self, int,
                                                  const QString &msg) {
        if (m_replyOid != requestOid || m_replyType != requestType ||
            m_replyContextKey != requestKey)
          return;
        m_commentReplyHasMore = false;
        emit replyHasMoreChanged();
        self->commentReplyListModel()->setLoading(false);
        self->commentReplyListModel()->setErrorMessage(msg);
        emit self->toastMessage(QString("回复加载失败：%1").arg(msg));
      });
}

void BiliCommentModule::fetchMoreCommentReplies() {
  fetchMoreCommentRepliesForContext(m_replyOid, m_replyType, m_replyContextKey);
}

void BiliCommentModule::fetchMoreCommentRepliesForContext(const QString &oid, int type,
                                                          const QString &contextKey) {
  if (m_currentCommentRootRpid <= 0) return;
  if (!m_commentReplyHasMore) return;
  if (m_controller->commentReplyListModel()->loading()) return;

  const QString requestOidString = oid.trimmed();
  const QString requestContextKey =
      contextKey.isEmpty() ? QString("%1:%2").arg(type).arg(requestOidString) : contextKey;
  if (requestOidString.isEmpty() || requestOidString == "0" ||
      type <= 0 || requestContextKey.isEmpty()) return;
  if (m_replyOid != requestOidString || m_replyType != type ||
      m_replyContextKey != requestContextKey)
    return;

  m_commentReplyPage++;
  m_controller->commentReplyListModel()->setLoading(true);

  QMap<QString, QString> params;
  params["oid"] = requestOidString;
  params["type"] = QString::number(type);
  params["root"] = QString::number(m_currentCommentRootRpid);
  params["ps"] = "20";
  params["pn"] = QString::number(m_commentReplyPage);

  const qint64 requestRootRpid = m_currentCommentRootRpid;
  const int requestPage = m_commentReplyPage;
  const QString requestOid = requestOidString;
  const int requestType = type;
  const QString requestKey = requestContextKey;
  BiliListFetch::fetchParsed(
      m_controller, BiliListFetch::Via::Api, "/video/comments/replies", params,
      [this, requestOid, requestType, requestKey](BiliController *) {
        return m_replyOid == requestOid && m_replyType == requestType &&
               m_replyContextKey == requestKey;
      },
      [requestPage](const QJsonObject &data) {
        return parseCommentRepliesPayload(data, requestPage);
      },
      [this, requestRootRpid, requestOid, requestType,
       requestKey](BiliController *self, ParsedCommentReplies result) {
        if (m_replyOid != requestOid || m_replyType != requestType ||
            m_replyContextKey != requestKey || m_currentCommentRootRpid != requestRootRpid ||
            m_commentReplyPage != result.page)
          return;

        m_commentReplyHasMore = result.hasMore;
        emit replyHasMoreChanged();

        if (result.total > 0) {
          self->commentReplyListModel()->setTotalCount(result.total);
        } else {
          const int loaded = self->commentReplyListModel()->count() + result.items.size();
          if (loaded > self->commentReplyListModel()->totalCount())
            self->commentReplyListModel()->setTotalCount(loaded);
        }
        self->commentReplyListModel()->appendItems(result.items);
        self->commentReplyListModel()->setLoading(false);
      },
      [this, requestOid, requestType, requestKey,
       requestPage](BiliController *self, int, const QString &msg) {
        if (m_replyOid != requestOid || m_replyType != requestType ||
            m_replyContextKey != requestKey)
          return;
        // 失败时回退页码，避免跳页导致后续页永远加载不到。
        if (m_commentReplyPage == requestPage && m_commentReplyPage > 1) {
          m_commentReplyPage--;
        }
        self->commentReplyListModel()->setLoading(false);
        emit self->toastMessage(QString("回复加载失败：%1").arg(msg));
      });
}

void BiliCommentModule::fetchMoreComments() {
  fetchMoreCommentsForContext(m_commentOid, m_commentType, m_commentBvid);
}

void BiliCommentModule::fetchMoreCommentsForContext(const QString &oid, int type,
                                                    const QString &contextKey) {
  if (m_controller->commentListModel()->loading())
    return;
  if (!m_commentHasMore)
    return;
  const QString requestOidString = oid.trimmed();
  const QString requestContextKey =
      contextKey.isEmpty() ? QString("%1:%2").arg(type).arg(requestOidString) : contextKey;
  if (requestOidString.isEmpty() || requestOidString == "0" ||
      type <= 0 || requestContextKey.isEmpty()) return;
  if (m_commentBvid != requestContextKey || m_commentOid != requestOidString ||
      m_commentType != type) {
    return;
  }
  m_commentPage++;
  fetchCommentsForContext(requestOidString, type, requestContextKey, m_commentPage);
}
