#include "modules/favorite/BiliFavoriteModule.h"
#include "BiliAsyncUtils.hpp"
#include "BiliController.h"
#include "BiliJsonUtils.h"
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

struct ParsedFavoriteItems {
  qint64 mediaId = 0;
  int page = 1;
  QVector<VideoItem> items;
  bool hasMore = false;
};

QVector<FavoriteFolderItem> parseFavoriteFoldersPayload(const QJsonObject &data) {
  QJsonArray list = data.value("list").toArray();
  QVector<FavoriteFolderItem> items;
  items.reserve(list.size());
  for (const QJsonValue &v : list) {
    if (v.isObject()) {
      items.append(FavoriteFolderModel::parseFavoriteFolderItem(v.toObject()));
    }
  }
  return items;
}

ParsedFavoriteItems parseFavoriteItemsPayload(const QJsonObject &data,
                                              qint64 mediaId, int page) {
  ParsedFavoriteItems result;
  result.mediaId = mediaId;
  result.page = page;

  QJsonArray list = data.value("medias").toArray();
  result.items.reserve(list.size());
  for (const QJsonValue &v : list) {
    if (!v.isObject())
      continue;

    QJsonObject obj = v.toObject();
    VideoItem item = VideoListModel::parseVideoItem(obj);
    item.pic = obj.value("cover").toString();
    item.duration = obj.value("duration").toInt();

    QJsonObject upper = obj.value("upper").toObject();
    item.ownerName = upper.value("name").toString();
    item.ownerMid = upper.value("mid").toVariant().toLongLong();
    item.ownerFace = upper.value("face").toString();

    QJsonObject cntInfo = obj.value("cnt_info").toObject();
    item.views = cntInfo.value("play").toVariant().toLongLong();
    if (item.views <= 0) {
      item.views = cntInfo.value("view").toVariant().toLongLong();
    }
    item.danmaku = cntInfo.value("danmaku").toVariant().toLongLong();
    item.likes = cntInfo.value("like").toVariant().toLongLong();
    item.favorites = cntInfo.value("favorite").toVariant().toLongLong();

    result.items.append(item);
  }

  const bool hasMore = data.value("has_more").toBool(false);
  result.hasMore = hasMore ? true : !result.items.isEmpty();
  return result;
}

} // namespace

BiliFavoriteModule::BiliFavoriteModule(BiliController *controller)
    : QObject(controller), m_controller(controller) {}

QObject *BiliFavoriteModule::favoriteFolderModel() { return m_controller->m_favoriteFolderModel; }
QObject *BiliFavoriteModule::favoriteItemModel() { return m_controller->m_favoriteItemModel; }

void BiliFavoriteModule::resetLoadingState() {
  m_favoriteStatusLoadingAid = 0;
  m_coinStatusLoadingAid = 0;
  m_likeStatusLoadingAid = 0;
  m_watchLaterStatusLoadingAid = 0;
}

// ====== API: 收藏夹 ======

void BiliFavoriteModule::fetchFavoriteFolders() {
  if (!m_controller->m_loggedIn || m_controller->m_userId <= 0) {
    emit m_controller->toastMessage("请先登录后查看收藏夹");
    return;
  }
  if (m_controller->m_favoriteFolderModel->loading())
    return;

  m_controller->m_favoriteFolderModel->setLoading(true);

  QMap<QString, QString> params;
  params["mid"] = QString::number(m_controller->m_userId);

  QPointer<BiliController> self(m_controller);
  m_controller->apiGet(
      "/fav/folder/list", params,
      [self](const QJsonObject &data) {
        if (!self || !self->m_favoriteFolderModel)
          return;
        biliRunInWorker(
            self, [data]() { return parseFavoriteFoldersPayload(data); },
            [self](QVector<FavoriteFolderItem> items) {
              if (!self || !self->m_favoriteFolderModel)
                return;

              self->m_favoriteFolderModel->setItems(items);
              self->m_favoriteFolderModel->setLoading(false);

              for (const FavoriteFolderItem &folder : items) {
                QMap<QString, QString> p;
                qint64 mediaId = folder.id > 0 ? folder.id : folder.fid;
                if (mediaId <= 0) continue;
                p["media_id"] = QString::number(mediaId);
                p["pn"] = "1";
                p["ps"] = "1";
                p["order"] = "mtime";
                p["type"] = "0";

                QPointer<BiliController> self2(self);
                self->m_network->get(
                    "/fav/resource/list", p,
                    [self2, mediaId](const QJsonObject &data2) {
                      if (!self2) return;
                      QJsonArray medias = data2.value("medias").toArray();
                      if (!medias.isEmpty()) {
                        QJsonObject first = medias.first().toObject();
                        QString cover = first.value("cover").toString();
                        if (!cover.isEmpty()) {
                          self2->m_favoriteFolderModel->updateCover(mediaId, cover);
                        }
                      }
                    },
                    nullptr);
              }

              if (items.isEmpty()) {
                emit self->toastMessage("暂无收藏夹");
              }
            });
      },
      [this](int, const QString &msg) {
        m_controller->m_favoriteFolderModel->setLoading(false);
        emit m_controller->toastMessage(QString("收藏夹加载失败：%1").arg(msg));
      },
      true);
}

void BiliFavoriteModule::fetchFavoriteItems(qint64 mediaId, int page, int pageSize) {
  if (mediaId <= 0) {
    emit m_controller->toastMessage("收藏夹 ID 无效");
    return;
  }
  if (m_controller->m_favoriteItemModel->loading())
    return;

  page = qBound(1, page, 2000);
  pageSize = qBound(1, pageSize, 20);

  m_currentFavoriteId = mediaId;
  m_favoritePage = page;

  if (page == 1) {
    m_controller->m_favoriteItemModel->clear();
  }
  m_controller->m_favoriteItemModel->setLoading(true);
  m_controller->m_favoriteItemModel->setErrorMessage("");

  QMap<QString, QString> params;
  params["media_id"] = QString::number(mediaId);
  params["pn"] = QString::number(page);
  params["ps"] = QString::number(pageSize);
  params["order"] = "mtime";
  params["type"] = "0";

  QPointer<BiliController> self(m_controller);
  const qint64 requestMediaId = mediaId;
  const int requestPage = page;
  m_controller->apiGet(
      "/fav/resource/list", params,
      [this, self, requestMediaId, requestPage](const QJsonObject &data) {
        if (!self || !self->m_favoriteItemModel)
          return;
        biliRunInWorker(
            self,
            [data, requestMediaId, requestPage]() {
              return parseFavoriteItemsPayload(data, requestMediaId, requestPage);
            },
            [this, self](ParsedFavoriteItems result) {
              if (!self || !self->m_favoriteItemModel ||
                  m_currentFavoriteId != result.mediaId ||
                  m_favoritePage != result.page) {
                return;
              }

              self->m_favoriteItemModel->appendItems(result.items);
              self->m_favoriteItemModel->setHasMore(result.hasMore);
              self->m_favoriteItemModel->setLoading(false);

              if (result.items.isEmpty() && result.page == 1) {
                self->m_favoriteItemModel->setErrorMessage("收藏夹为空");
              }
            });
      },
      [this](int, const QString &msg) {
        m_controller->m_favoriteItemModel->setLoading(false);
        m_controller->m_favoriteItemModel->setErrorMessage(msg);
        emit m_controller->toastMessage(QString("收藏夹加载失败：%1").arg(msg));
      },
      true);
}

void BiliFavoriteModule::fetchMoreFavoriteItems() {
  if (!m_controller->m_favoriteItemModel->hasMore() || m_controller->m_favoriteItemModel->loading())
    return;
  if (m_controller->m_favoriteItemModel->count() <= 0)
    return;
  m_favoritePage++;
  fetchFavoriteItems(m_currentFavoriteId, m_favoritePage);
}

// ====== API: 收藏状态 ======

void BiliFavoriteModule::fetchFavoriteStatus() {
  if (!m_controller->m_loggedIn) {
    return;
  }
  if (m_controller->m_currentVideo.aid <= 0) {
    return;
  }
  const qint64 aid = m_controller->m_currentVideo.aid;
  if (m_favoriteStatusLoadingAid == aid) {
    return;
  }
  m_favoriteStatusLoadingAid = aid;

  QMap<QString, QString> params;
  params["aid"] = QString::number(aid);
  params["bvid"] = m_controller->m_currentVideo.bvid;
  const qint64 requestAid = aid;

  m_controller->apiGet(
      "/video/relation", params,
      [this, requestAid](const QJsonObject &data) {
        if (m_favoriteStatusLoadingAid == requestAid) {
          m_favoriteStatusLoadingAid = 0;
        }
        if (!m_controller || m_controller->m_currentVideo.aid != requestAid) {
          return;
        }

        auto intValue = [](const QJsonValue &value) {
          if (value.isBool()) return value.toBool() ? 1 : 0;
          if (value.isString()) return value.toString().toInt();
          return value.toInt(0);
        };

        const bool fav = intValue(data.value("favorite")) > 0 ||
                         intValue(data.value("favoured")) > 0;
        const bool coined = intValue(data.value("coin")) > 0 ||
                            intValue(data.value("multiply")) > 0;
        const bool liked = intValue(data.value("like")) > 0 ||
                           intValue(data.value("liked")) == 1;
        const bool watchLater = intValue(data.value("watchlater")) > 0 ||
                                intValue(data.value("watch_later")) > 0;

        m_controller->setFavoriteState(fav);
        m_controller->setCoinState(coined);
        m_controller->setLikeState(liked);
        m_controller->setWatchLaterState(watchLater);
      },
      [this, requestAid](int, const QString &msg) {
        if (m_favoriteStatusLoadingAid == requestAid) {
          m_favoriteStatusLoadingAid = 0;
        }
        if (!m_controller || m_controller->m_currentVideo.aid != requestAid) {
          return;
        }
        emit m_controller->toastMessage(QString("获取视频关系状态失败：%1").arg(msg));
      });
}

void BiliFavoriteModule::fetchCoinStatus() {
  if (!m_controller->m_loggedIn) {
    return;
  }
  if (m_controller->m_currentVideo.aid <= 0) {
    return;
  }
  const qint64 aid = m_controller->m_currentVideo.aid;
  if (m_coinStatusLoadingAid == aid) {
    return;
  }
  m_coinStatusLoadingAid = aid;

  QMap<QString, QString> params;
  params["aid"] = QString::number(aid);
  const qint64 requestAid = aid;

  m_controller->apiGet(
      "/coin/status", params,
      [this, requestAid](const QJsonObject &data) {
        if (m_coinStatusLoadingAid == requestAid) {
          m_coinStatusLoadingAid = 0;
        }
        if (!m_controller || m_controller->m_currentVideo.aid != requestAid) {
          return;
        }

        bool coined = false;
        int multiply = data.value("multiply").toInt(0);
        if (multiply > 0) {
          coined = true;
        } else if (data.value("multiply").isString()) {
          coined = data.value("multiply").toString().toInt() > 0;
        }
        m_controller->setCoinState(coined);
      },
      [this, requestAid](int, const QString &msg) {
        if (m_coinStatusLoadingAid == requestAid) {
          m_coinStatusLoadingAid = 0;
        }
        if (!m_controller || m_controller->m_currentVideo.aid != requestAid) {
          return;
        }
        emit m_controller->toastMessage(QString("获取投币状态失败：%1").arg(msg));
      });
}

void BiliFavoriteModule::addCoin(int multiply, bool selectLike) {
  if (!m_controller->m_loggedIn) {
    emit m_controller->toastMessage("请先登录后再投币");
    return;
  }
  if (m_controller->m_currentVideo.aid <= 0) {
    emit m_controller->toastMessage("视频信息不完整");
    return;
  }
  if (m_controller->m_isCoined) {
    emit m_controller->toastMessage("已经投过币了");
    return;
  }

  multiply = qBound(1, multiply, 2);

  QMap<QString, QString> params;
  params["aid"] = QString::number(m_controller->m_currentVideo.aid);
  params["bvid"] = m_controller->m_currentVideo.bvid;
  params["multiply"] = QString::number(multiply);
  params["select_like"] = selectLike ? "1" : "0";

  QPointer<BiliController> self(m_controller);
  m_controller->m_network->get(
      "/coin/add", params,
      [self, multiply, selectLike](const QJsonObject &) {
        if (!self)
          return;
        self->setCoinState(true);
        self->m_currentVideo.coins += multiply;
        if (selectLike && !self->isLiked()) {
          self->setLikeState(true);
          self->m_currentVideo.likes += 1;
        }
        emit self->videoStatsChanged();
        emit self->toastMessage(QString("投币成功（%1个）").arg(multiply));
      },
      [self](int, const QString &msg) {
        if (!self)
          return;
        emit self->toastMessage(QString("投币失败：%1").arg(msg));
      });
}

void BiliFavoriteModule::fetchLikeStatus() {
  if (!m_controller->m_loggedIn) {
    return;
  }
  if (m_controller->m_currentVideo.aid <= 0) {
    return;
  }
  const qint64 aid = m_controller->m_currentVideo.aid;
  if (m_likeStatusLoadingAid == aid) {
    return;
  }
  m_likeStatusLoadingAid = aid;

  QMap<QString, QString> params;
  params["aid"] = QString::number(aid);
  const qint64 requestAid = aid;

  m_controller->apiGet(
      "/like/status", params,
      [this, requestAid](const QJsonObject &data) {
        if (m_likeStatusLoadingAid == requestAid) {
          m_likeStatusLoadingAid = 0;
        }
        if (!m_controller || m_controller->m_currentVideo.aid != requestAid) {
          return;
        }

        int liked = 0;
        if (data.value("liked").isBool()) {
          liked = data.value("liked").toBool() ? 1 : 0;
        } else if (data.value("liked").isString()) {
          liked = data.value("liked").toString().toInt();
        } else {
          liked = data.value("liked").toInt(0);
        }
        bool isLiked = liked == 1;
        m_controller->setLikeState(isLiked);
      },
      [this, requestAid](int, const QString &msg) {
        if (m_likeStatusLoadingAid == requestAid) {
          m_likeStatusLoadingAid = 0;
        }
        if (!m_controller || m_controller->m_currentVideo.aid != requestAid) {
          return;
        }
        emit m_controller->toastMessage(QString("获取点赞状态失败：%1").arg(msg));
      });
}

void BiliFavoriteModule::fetchWatchLaterStatus() {
  if (!m_controller->m_loggedIn) {
    return;
  }
  if (m_controller->m_currentVideo.aid <= 0) {
    return;
  }
  const qint64 aid = m_controller->m_currentVideo.aid;
  if (m_watchLaterStatusLoadingAid == aid) {
    return;
  }
  m_watchLaterStatusLoadingAid = aid;
  const qint64 requestAid = aid;
  const QString requestBvid = m_controller->m_currentVideo.bvid;

  QMap<QString, QString> params;
  params["pn"] = "1";
  params["ps"] = "100";

  m_controller->apiGet(
      "/toview/list", params,
      [this, requestAid, requestBvid](const QJsonObject &data) {
        if (m_watchLaterStatusLoadingAid == requestAid) {
          m_watchLaterStatusLoadingAid = 0;
        }
        if (!m_controller ||
            m_controller->m_currentVideo.aid != requestAid ||
            m_controller->m_currentVideo.bvid != requestBvid) {
          return;
        }
        QJsonArray list = data.value("list").toArray();
        if (list.isEmpty()) {
          list = data.value("data").toArray();
        }

        bool found = false;
        for (const QJsonValue &v : list) {
          if (!v.isObject())
            continue;
          QJsonObject obj = v.toObject();
          qint64 aid = obj.value("aid").toVariant().toLongLong();
          QString bvid = obj.value("bvid").toString();
          if ((aid > 0 && aid == m_controller->m_currentVideo.aid) || (!bvid.isEmpty() && bvid == m_controller->m_currentVideo.bvid)) {
            found = true;
            break;
          }
        }

        m_controller->setWatchLaterState(found);
      },
      [this, requestAid, requestBvid](int, const QString &msg) {
        if (m_watchLaterStatusLoadingAid == requestAid) {
          m_watchLaterStatusLoadingAid = 0;
        }
        if (!m_controller ||
            m_controller->m_currentVideo.aid != requestAid ||
            m_controller->m_currentVideo.bvid != requestBvid) {
          return;
        }
        emit m_controller->toastMessage(QString("获取稍后再看状态失败：%1").arg(msg));
      });
}

void BiliFavoriteModule::toggleLike() {
  if (!m_controller->m_loggedIn) {
    emit m_controller->toastMessage("请先登录后再点赞");
    return;
  }
  if (m_controller->m_currentVideo.aid <= 0) {
    emit m_controller->toastMessage("视频信息不完整");
    return;
  }

  int likeAction = m_controller->m_isLiked ? 2 : 1; // 1=点赞,2=取消

  QMap<QString, QString> params;
  params["aid"] = QString::number(m_controller->m_currentVideo.aid);
  params["bvid"] = m_controller->m_currentVideo.bvid;
  params["like"] = QString::number(likeAction);

  QPointer<BiliController> self(m_controller);
  m_controller->m_network->get(
      "/like/toggle", params,
      [self, likeAction](const QJsonObject &) {
        if (!self)
          return;
        bool newLiked = (likeAction == 1);
        self->setLikeState(newLiked);
        if (newLiked) {
          self->m_currentVideo.likes += 1;
          emit self->toastMessage("点赞爆棚，感谢推荐！");
        } else {
          self->m_currentVideo.likes = qMax<qint64>(0, self->m_currentVideo.likes - 1);
          emit self->toastMessage("已取消点赞");
        }
        emit self->videoStatsChanged();
      },
      [self](int, const QString &msg) {
        if (!self)
          return;
        emit self->toastMessage(QString("点赞操作失败：%1").arg(msg));
      });
}

void BiliFavoriteModule::toggleFavorite() {
  if (!m_controller->m_loggedIn) {
    emit m_controller->toastMessage("请先登录后再收藏");
    return;
  }
  if (m_controller->m_currentVideo.aid <= 0) {
    emit m_controller->toastMessage("视频信息不完整");
    return;
  }

  if (m_controller->m_isFavorited) {
    QMap<QString, QString> params;
    params["aid"] = QString::number(m_controller->m_currentVideo.aid);
    params["action"] = "0";

    QPointer<BiliController> self(m_controller);
    m_controller->m_network->get(
        "/fav/toggle", params,
        [self](const QJsonObject &) {
          if (!self)
            return;
          self->setFavoriteState(false);
          self->m_currentVideo.favorites = qMax<qint64>(0, self->m_currentVideo.favorites - 1);
          emit self->videoStatsChanged();
          emit self->toastMessage("已取消收藏");
        },
        [self](int, const QString &msg) {
          if (!self)
            return;
          emit self->toastMessage(QString("取消收藏失败：%1").arg(msg));
        });
    return;
  }

  fetchFavoriteFolders();
  emit m_controller->toastMessage("请选择收藏夹");
}

void BiliFavoriteModule::toggleFavoriteTo(qint64 mediaId) {
  if (!m_controller->m_loggedIn) {
    emit m_controller->toastMessage("请先登录后再收藏");
    return;
  }
  if (m_controller->m_currentVideo.aid <= 0) {
    emit m_controller->toastMessage("视频信息不完整");
    return;
  }
  if (mediaId <= 0) {
    emit m_controller->toastMessage("收藏夹无效");
    return;
  }

  QMap<QString, QString> params;
  params["aid"] = QString::number(m_controller->m_currentVideo.aid);
  params["action"] = "1";
  params["media_id"] = QString::number(mediaId);

  QPointer<BiliController> self(m_controller);

  m_controller->m_network->get(
      "/fav/toggle", params,
      [self](const QJsonObject &) {
        if (!self)
          return;

        self->setFavoriteState(true);
        self->m_currentVideo.favorites += 1;
        emit self->videoStatsChanged();
        emit self->toastMessage("已收藏到收藏夹");
      },
      [self](int, const QString &msg) {
        if (!self)
          return;
        emit self->toastMessage(QString("收藏操作失败：%1").arg(msg));
      });
}

void BiliFavoriteModule::toggleWatchLater() {
  if (!m_controller->m_loggedIn) {
    emit m_controller->toastMessage("请先登录后再添加稍后再看");
    return;
  }
  if (m_controller->m_currentVideo.aid <= 0) {
    emit m_controller->toastMessage("视频信息不完整");
    return;
  }

  const QString apiPath = m_controller->m_isWatchLater ? "/toview/del" : "/toview/add";
  const QString okMsg = m_controller->m_isWatchLater ? "已从稍后再看移除" : "已添加到稍后再看";

  QMap<QString, QString> params;
  params["aid"] = QString::number(m_controller->m_currentVideo.aid);
  // 删除接口只支持 aid，添加接口支持 aid 和 bvid
  if (!m_controller->m_isWatchLater) {
    params["bvid"] = m_controller->m_currentVideo.bvid;
  }

  QPointer<BiliController> self(m_controller);
  m_controller->m_network->get(
      apiPath, params,
      [self, okMsg](const QJsonObject &) {
        if (!self)
          return;
        self->setWatchLaterState(!self->isWatchLater());
        emit self->toastMessage(okMsg);
      },
      [self](int, const QString &msg) {
        if (!self)
          return;
        emit self->toastMessage(QString("稍后再看操作失败：%1").arg(msg));
      });
}
