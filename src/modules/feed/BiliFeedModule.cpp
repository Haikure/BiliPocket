#include "modules/feed/BiliFeedModule.h"
#include "BiliAsyncUtils.hpp"
#include "BiliController.h"
#include "BiliJsonUtils.h"
#include "BiliListFetch.hpp"
#include "BiliModels.h"
#include "BiliNetwork.h"
#include "modules/history/BiliHistoryModule.h"
#include "modules/login/BiliLoginModule.h"
#include "modules/search/BiliSearchModule.h"
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
#include <QSet>
#include <QStandardPaths>
#include <QStringListModel>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>
#include <QtGlobal>
#include <algorithm>
#include <functional>

namespace {

struct ParsedVideoList {
  int page = 1;
  QVector<VideoItem> items;
  bool hasMore = false;
};

struct ParsedDynamicList {
  QString offset;
  QString requestOffset;
  QVector<DynamicItem> items;
  bool hasMore = false;
};

ParsedVideoList parsePopularPayload(const QJsonObject &data, int page) {
  ParsedVideoList result;
  result.page = page;

  QJsonArray list = data.value("list").toArray();
  if (list.isEmpty()) {
    list = data.value("item").toArray();
  }
  if (list.isEmpty()) {
    list = data.value("items").toArray();
  }

  result.items.reserve(list.size());
  for (const QJsonValue &v : list) {
    if (v.isObject()) {
      result.items.append(VideoListModel::parseVideoItem(v.toObject()));
    }
  }

  const bool noMore = data.value("no_more").toBool(false);
  result.hasMore = noMore ? false : !result.items.isEmpty();
  return result;
}

QVector<VideoItem> parseRankingPayload(const QJsonObject &data) {
  QJsonArray list = data.value("list").toArray();
  QVector<VideoItem> items;
  items.reserve(list.size());
  for (const QJsonValue &v : list) {
    if (v.isObject()) {
      items.append(VideoListModel::parseVideoItem(v.toObject()));
    }
  }
  return items;
}

ParsedDynamicList parseDynamicPayload(const QJsonObject &data, const QString &requestOffset) {
  ParsedDynamicList result;
  result.requestOffset = requestOffset;
  result.offset = data.value("offset").toString();
  result.hasMore = data.value("has_more").toBool(false);

  const QJsonArray list = data.value("items").toArray();
  result.items.reserve(list.size());
  QSet<QString> seen;
  for (const QJsonValue &v : list) {
    if (!v.isObject())
      continue;
    DynamicItem item = DynamicListModel::parseDynamicItem(v.toObject());
    if (item.idStr.isEmpty() || seen.contains(item.idStr))
      continue;
    seen.insert(item.idStr);
    result.items.append(item);
  }

  if (result.offset.isEmpty() || result.items.isEmpty())
    result.hasMore = false;
  return result;
}

} // namespace

BiliFeedModule::BiliFeedModule(BiliController *controller)
    : QObject(controller), m_controller(controller) {}

QObject *BiliFeedModule::popularModel() { return m_controller->popularListModel(); }
QObject *BiliFeedModule::rankingModel() { return m_controller->rankingListModel(); }
QObject *BiliFeedModule::dynamicModel() { return m_controller->dynamicListModel(); }
QObject *BiliFeedModule::upDynamicModel() { return m_controller->upDynamicListModel(); }
QObject *BiliFeedModule::hotSearchModel() { return m_controller->hotSearchListModel(); }

// ====== API: 热门视频 ======

void BiliFeedModule::fetchPopular(int page, int pageSize) {
  if (m_controller->popularListModel()->loading())
    return;

  // 参数校验
  page = qBound(1, page, 1000);
  pageSize = qBound(1, pageSize, 30);

  m_popularPage = page;
  if (page == 1) {
    m_controller->popularListModel()->clear();
  }
  m_controller->popularListModel()->setLoading(true);
  m_controller->popularListModel()->setErrorMessage("");
  m_controller->setIsLoading(true);

  QString apiPath = "/recommend";

  QMap<QString, QString> paramsRecommend;
  // fresh_type: 3 表示换一换推荐，4 用于后续刷新
  paramsRecommend["fresh_type"] = (page <= 1) ? "3" : "4";

  VideoListModel *popularModel = m_controller->popularListModel();

  BiliListFetch::fetchParsed(
      m_controller, BiliListFetch::Via::Network, apiPath, paramsRecommend,
      [popularModel](BiliController *) { return popularModel != nullptr; },
      [page](const QJsonObject &data) { return parsePopularPayload(data, page); },
      [this, popularModel](BiliController *self, ParsedVideoList result) {
        if (!popularModel || m_popularPage != result.page)
          return;
        popularModel->appendItems(result.items);
        popularModel->setHasMore(result.hasMore);
        popularModel->setLoading(false);
        self->setIsLoading(false);

        if (result.items.isEmpty() && result.page == 1) {
          popularModel->setErrorMessage("暂无推荐视频");
        }
      },
      [this, popularModel, page](BiliController *self, int code,
                                 const QString &msg) {
        if (!popularModel)
          return;

        if (code == -101 || code == -401 || code == 401) {
          self->clearLocalLoginState();
        }

        if (m_popularPage == page && m_popularPage > 1) {
          m_popularPage--;
        }
        popularModel->setLoading(false);
        popularModel->setErrorMessage(msg);
        self->setIsLoading(false);
        emit self->toastMessage(QString("加载失败：%1").arg(msg));
      });
}

void BiliFeedModule::fetchMorePopular() {
  if (!m_controller->popularListModel()->hasMore() || m_controller->popularListModel()->loading())
    return;
  if (m_controller->popularListModel()->count() <= 0)
    return;
  m_popularPage++;
  fetchPopular(m_popularPage, 10);
}

// ====== API: 排行榜 ======

void BiliFeedModule::fetchRanking(int rid) {
  if (m_controller->rankingListModel()->loading())
    return;

  rid = qBound(0, rid, 9999);

  m_controller->rankingListModel()->clear();
  m_controller->rankingListModel()->setLoading(true);
  m_controller->setIsLoading(true);

  QMap<QString, QString> params;
  params["rid"] = QString::number(rid);
  params["type"] = "all";

  VideoListModel *rankingModel = m_controller->rankingListModel();

  BiliListFetch::fetchParsed(
      m_controller, BiliListFetch::Via::Network, "/ranking", params,
      [rankingModel](BiliController *) { return rankingModel != nullptr; },
      [](const QJsonObject &data) { return parseRankingPayload(data); },
      [rankingModel](BiliController *self, QVector<VideoItem> items) {
        if (!rankingModel)
          return;
        rankingModel->appendItems(items);
        rankingModel->setHasMore(false);
        rankingModel->setLoading(false);
        self->setIsLoading(false);
      },
      [rankingModel](BiliController *self, int code, const QString &msg) {
        Q_UNUSED(code)
        if (!rankingModel)
          return;

        rankingModel->setLoading(false);
        rankingModel->setErrorMessage(msg);
        self->setIsLoading(false);
        emit self->toastMessage(QString("排行榜加载失败：%1").arg(msg));
      });
}

// ====== API: 动态 ======

void BiliFeedModule::fetchDynamic(const QString &type, const QString &offset, qint64 hostMid) {
  DynamicListModel *model = m_controller->dynamicListModel();
  if (!model || model->loading())
    return;

  const QString normalizedType = type.trimmed().isEmpty() ? QStringLiteral("all") : type.trimmed().left(20);
  const QString requestOffset = offset.trimmed();
  const bool firstPage = requestOffset.isEmpty();

  if (firstPage) {
    model->clear();
    m_dynamicOffset.clear();
  }
  m_dynamicType = normalizedType;
  m_dynamicHostMid = qMax<qint64>(0, hostMid);

  model->setLoading(true);
  model->setErrorMessage("");
  m_controller->setIsLoading(true);

  QMap<QString, QString> params;
  params["type"] = normalizedType;
  if (!requestOffset.isEmpty()) params["offset"] = requestOffset;
  if (m_dynamicHostMid > 0) params["host_mid"] = QString::number(m_dynamicHostMid);

  BiliListFetch::fetchParsed(
      m_controller, BiliListFetch::Via::Network, "/dynamic/feed", params,
      [model](BiliController *) { return model != nullptr; },
      [requestOffset](const QJsonObject &data) {
        return parseDynamicPayload(data, requestOffset);
      },
      [this, model](BiliController *self, ParsedDynamicList result) {
        if (!model)
          return;
        if (result.requestOffset != m_dynamicOffset && !result.requestOffset.isEmpty()) {
          model->setLoading(false);
          self->setIsLoading(false);
          return;
        }

        model->appendItems(result.items);
        m_dynamicOffset = result.offset;
        model->setHasMore(result.hasMore);
        model->setLoading(false);
        self->setIsLoading(false);

        if (model->count() == 0) {
          model->setErrorMessage(QStringLiteral("暂无动态"));
        }
      },
      [model](BiliController *self, int code, const QString &msg) {
        if (!model)
          return;

        if (code == -101 || code == -401 || code == 401) {
          self->clearLocalLoginState();
        }

        model->setLoading(false);
        model->setErrorMessage(msg);
        self->setIsLoading(false);
        emit self->toastMessage(QString("动态加载失败：%1").arg(msg));
      });
}

void BiliFeedModule::fetchMoreDynamic() {
  DynamicListModel *model = m_controller->dynamicListModel();
  if (!model || model->loading() || !model->hasMore() || m_dynamicOffset.isEmpty())
    return;
  fetchDynamic(m_dynamicType, m_dynamicOffset, m_dynamicHostMid);
}

void BiliFeedModule::fetchUpDynamics(qint64 hostMid, const QString &offset) {
  DynamicListModel *model = m_controller->upDynamicListModel();
  if (!model || model->loading())
    return;

  hostMid = qMax<qint64>(0, hostMid);
  if (hostMid <= 0) {
    model->clear();
    model->setHasMore(false);
    model->setErrorMessage(QStringLiteral("UP 主信息无效"));
    return;
  }

  const QString requestOffset = offset.trimmed();
  const bool firstPage = requestOffset.isEmpty();
  if (firstPage || m_upDynamicHostMid != hostMid) {
    model->clear();
    m_upDynamicOffset.clear();
  }
  m_upDynamicHostMid = hostMid;

  model->setLoading(true);
  model->setErrorMessage("");
  m_controller->setIsLoading(true);

  QMap<QString, QString> params;
  params["type"] = QStringLiteral("all");
  params["host_mid"] = QString::number(hostMid);
  if (!requestOffset.isEmpty()) params["offset"] = requestOffset;

  BiliListFetch::fetchParsed(
      m_controller, BiliListFetch::Via::Network, "/dynamic/feed", params,
      [model](BiliController *) { return model != nullptr; },
      [requestOffset](const QJsonObject &data) {
        return parseDynamicPayload(data, requestOffset);
      },
      [this, model, hostMid](BiliController *self, ParsedDynamicList result) {
        if (!model)
          return;
        if (m_upDynamicHostMid != hostMid ||
            (result.requestOffset != m_upDynamicOffset && !result.requestOffset.isEmpty())) {
          model->setLoading(false);
          self->setIsLoading(false);
          return;
        }

        model->appendItems(result.items);
        m_upDynamicOffset = result.offset;
        model->setHasMore(result.hasMore);
        model->setLoading(false);
        self->setIsLoading(false);

        if (model->count() == 0) {
          model->setErrorMessage(QStringLiteral("暂无图文动态"));
        }
      },
      [model](BiliController *self, int code, const QString &msg) {
        if (!model)
          return;

        if (code == -101 || code == -401 || code == 401) {
          self->clearLocalLoginState();
        }

        model->setLoading(false);
        model->setErrorMessage(msg);
        self->setIsLoading(false);
        emit self->toastMessage(QString("UP 动态加载失败：%1").arg(msg));
      });
}

void BiliFeedModule::fetchMoreUpDynamics() {
  DynamicListModel *model = m_controller->upDynamicListModel();
  if (!model || model->loading() || !model->hasMore() ||
      m_upDynamicOffset.isEmpty() || m_upDynamicHostMid <= 0) {
    return;
  }
  fetchUpDynamics(m_upDynamicHostMid, m_upDynamicOffset);
}

// ====== API: 热搜 ======

void BiliFeedModule::fetchHotSearch() {
  // 热搜实现在搜索模块，这里只保留 QML 入口
  m_controller->searchModule()->fetchHotSearch();
}
