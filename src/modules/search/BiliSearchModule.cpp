#include "modules/search/BiliSearchModule.h"
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

struct ParsedSearchResults {
  QString keyword;
  int page = 1;
  QVector<VideoItem> items;
};

QVector<HotSearchItem> parseSearchHotPayload(const QJsonObject &data) {
  QJsonObject trending = data.value("trending").toObject();
  QJsonArray list = trending.value("list").toArray();

  QVector<HotSearchItem> items;
  items.reserve(qMin(list.size(), 50));
  int pos = 1;
  for (const QJsonValue &v : list) {
    if (pos > 50)
      break;
    QJsonObject obj = v.toObject();
    HotSearchItem item;
    item.keyword = obj.value("keyword").toString().left(100);
    item.icon = obj.value("icon").toString();
    item.position = pos++;
    items.append(item);
  }
  return items;
}

ParsedSearchResults parseSearchPayload(const QJsonObject &data,
                                       const QString &keyword, int page) {
  ParsedSearchResults result;
  result.keyword = keyword;
  result.page = page;

  QJsonArray list = data.value("result").toArray();
  if (list.isEmpty()) {
    list = data.value("list").toArray();
  }

  result.items.reserve(list.size());
  for (const QJsonValue &v : list) {
    if (v.isObject()) {
      result.items.append(VideoListModel::parseVideoItem(v.toObject()));
    }
  }
  return result;
}

} // namespace

BiliSearchModule::BiliSearchModule(BiliController *controller)
    : QObject(controller), m_controller(controller) {}

QObject *BiliSearchModule::searchModel() { return m_controller->searchListModel(); }
QObject *BiliSearchModule::searchHistoryModel() { return m_controller->searchHistoryListModel(); }
QObject *BiliSearchModule::hotSearchModel() { return m_controller->hotSearchListModel(); }

void BiliSearchModule::loadSearchHistory() {
  QSettings settings("BiliPocket", "BiliPlugin");
  m_searchHistory = settings.value("searchHistory").toStringList();
  m_controller->searchHistoryListModel()->setStringList(m_searchHistory);
}

void BiliSearchModule::saveSearchHistory() {
  QSettings settings("BiliPocket", "BiliPlugin");
  settings.setValue("searchHistory", m_searchHistory);
  settings.sync();
}

void BiliSearchModule::fetchHotSearch() {
  if (m_controller->hotSearchListModel()->loading())
    return;

  m_controller->hotSearchListModel()->setLoading(true);

  QMap<QString, QString> params;
  params["limit"] = "10";

  BiliListFetch::fetchParsed(
      m_controller, BiliListFetch::Via::Network, "/hot/search", params,
      BiliListFetch::acceptAlways,
      [](const QJsonObject &data) { return parseSearchHotPayload(data); },
      [](BiliController *self, QVector<HotSearchItem> items) {
        self->hotSearchListModel()->setItems(items);
        self->hotSearchListModel()->setLoading(false);
      },
      [](BiliController *self, int code, const QString &msg) {
        Q_UNUSED(code)
        self->hotSearchListModel()->setLoading(false);
        emit self->toastMessage(QString("热搜加载失败：%1").arg(msg));
      });
}

// ====== API: 搜索 ======

void BiliSearchModule::search(const QString &keyword, int page) {
  QString trimmed = keyword.trimmed();
  if (trimmed.isEmpty()) {
    emit m_controller->toastMessage("请输入搜索关键词");
    return;
  }
  if (m_controller->searchListModel()->loading())
    return;

  // 限制关键词长度
  if (trimmed.length() > 100) {
    trimmed = trimmed.left(100);
  }

  page = qBound(1, page, 100);

  m_searchKeyword = trimmed;
  m_searchPage = page;

  if (page == 1) {
    m_controller->searchListModel()->clear();
  }
  m_controller->searchListModel()->setKeyword(m_searchKeyword);
  m_controller->searchListModel()->setLoading(true);
  m_controller->setIsLoading(true);

  // 更新搜索历史
  m_searchHistory.removeAll(trimmed);          // 移除旧的重复项
  m_searchHistory.prepend(trimmed);            // 添加到最前面
  while (m_searchHistory.size() > 10) {         // 保持最多10个
    m_searchHistory.removeLast();
  }
  m_controller->searchHistoryListModel()->setStringList(m_searchHistory);
  saveSearchHistory();

  QMap<QString, QString> params;
  params["keyword"] = m_searchKeyword;
  params["page"] = QString::number(page);

  SearchResultModel *searchModel = m_controller->searchListModel();
  const QString requestKeyword = m_searchKeyword;
  const int requestPage = m_searchPage;

  BiliListFetch::fetchParsed(
      m_controller, BiliListFetch::Via::Network, "/search", params,
      [searchModel](BiliController *) { return searchModel != nullptr; },
      [requestKeyword, requestPage](const QJsonObject &data) {
        return parseSearchPayload(data, requestKeyword, requestPage);
      },
      [this, searchModel](BiliController *self, ParsedSearchResults result) {
        if (!searchModel || m_searchKeyword != result.keyword ||
            m_searchPage != result.page) {
          return;
        }

        searchModel->appendItems(result.items);
        searchModel->setHasMore(!result.items.isEmpty());
        searchModel->setLoading(false);
        self->setIsLoading(false);

        if (result.items.isEmpty() && result.page == 1) {
          searchModel->setErrorMessage(
              QString("未找到%1相关视频").arg(result.keyword));
        }
      },
      [this, searchModel, requestKeyword, requestPage](
          BiliController *self, int code, const QString &msg) {
        Q_UNUSED(code)
        if (!searchModel)
          return;

        if (m_searchKeyword == requestKeyword && m_searchPage == requestPage &&
            m_searchPage > 1) {
          m_searchPage--;
        }
        searchModel->setLoading(false);
        searchModel->setErrorMessage(msg);
        self->setIsLoading(false);
        emit self->toastMessage(QString("搜索失败：%1").arg(msg));
      });
}

void BiliSearchModule::searchMore() {
  if (!m_controller->searchListModel()->hasMore() || m_controller->searchListModel()->loading())
    return;
  m_searchPage++;
  search(m_searchKeyword, m_searchPage);
}

void BiliSearchModule::clearSearchHistory() {
  m_searchHistory.clear();
  m_controller->searchHistoryListModel()->setStringList(m_searchHistory);
  saveSearchHistory();
}

void BiliSearchModule::removeSearchHistory(const QString &keyword) {
  QString kw = keyword.trimmed();
  if (kw.isEmpty()) return;
  int removed = m_searchHistory.removeAll(kw);
  if (removed <= 0) return;
  m_controller->searchHistoryListModel()->setStringList(m_searchHistory);
  saveSearchHistory();
  emit m_controller->toastMessage(QString("已删除搜索历史：%1").arg(kw));
}
