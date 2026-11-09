#include "BiliDownloadQueue.h"
#include "BiliNetwork.h"
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QQmlEngine>

namespace {
QString taskKey(const QJsonObject &task) {
  return QStringLiteral("%1:%2:%3").arg(task.value("bvid").toString())
      .arg(task.value("cid").toVariant().toLongLong()).arg(task.value("quality").toInt());
}
}

BiliDownloadQueue *BiliDownloadQueue::s_instance = nullptr;
BiliDownloadQueue *BiliDownloadQueue::instance() {
  if (!s_instance) {
    s_instance = new BiliDownloadQueue();
    QQmlEngine::setObjectOwnership(s_instance, QQmlEngine::CppOwnership);
  }
  return s_instance;
}
void BiliDownloadQueue::destroyInstance() { delete s_instance; s_instance = nullptr; }
BiliDownloadQueue::BiliDownloadQueue(QObject *parent) : QAbstractListModel(parent) {
  m_poll.setInterval(800);
  connect(&m_poll, &QTimer::timeout, this, &BiliDownloadQueue::refresh);
  connect(BiliNetwork::instance(), &BiliNetwork::apiServerReadyChanged, this, &BiliDownloadQueue::refresh);
  connect(BiliNetwork::instance(), &BiliNetwork::apiServerRestartFailed, this, [this]() {
    m_error = QStringLiteral("服务启动失败，请在设置中重试");
    m_commands.clear();
    m_pendingTaskKeys.clear();
    emit queueChanged(); emit message(m_error);
  });
  m_poll.start();
  QTimer::singleShot(0, this, &BiliDownloadQueue::refresh);
}
int BiliDownloadQueue::rowCount(const QModelIndex &parent) const { return parent.isValid() ? 0 : m_tasks.size(); }
int BiliDownloadQueue::completedCount() const {
  int count = 0;
  for (const auto &task : m_tasks) if (task.value("state").toString() == "complete") ++count;
  return count;
}
QVariant BiliDownloadQueue::data(const QModelIndex &index, int role) const {
  if (!index.isValid() || index.row() < 0 || index.row() >= m_tasks.size() || role != Qt::UserRole+1) return {};
  return m_tasks.at(index.row()).toVariantMap();
}
QHash<int, QByteArray> BiliDownloadQueue::roleNames() const { return {{Qt::UserRole+1, "task"}}; }
void BiliDownloadQueue::enqueue(const QJsonObject &task) {
  const auto key = taskKey(task);
  // Include the request already in flight, before it appears in the next poll.
  if (m_pendingTaskKeys.contains(key)) {
    emit message(QStringLiteral("该视频正在加入队列，请勿重复点击"));
    return;
  }
  m_pendingTaskKeys.insert(key);
  if (!command("enqueue", {{"task", task}})) m_pendingTaskKeys.remove(key);
}
void BiliDownloadQueue::pauseAll() { command("pause"); }
void BiliDownloadQueue::startAll() { command("start"); }
void BiliDownloadQueue::clearCompleted() { command("clear_completed"); }
void BiliDownloadQueue::pauseTask(const QString &id) { command("pause_task", {{"id", id}}); }
void BiliDownloadQueue::resumeTask(const QString &id) { command("resume_task", {{"id", id}}); }
void BiliDownloadQueue::remove(const QString &id) { command("remove", {{"id", id}}); }
bool BiliDownloadQueue::command(const QString &action, const QJsonObject &extra) {
  if (m_commands.size() >= 32) { emit message(QStringLiteral("操作过多，请稍后重试")); return false; }
  auto body = extra; body.insert("action", action); m_commands.append(body);
  requestNext();
  return true;
}
void BiliDownloadQueue::refresh() { requestNext(); }
void BiliDownloadQueue::requestNext() {
  auto *network = BiliNetwork::instance();
  if (m_busy || !network->apiServerReady()) return;
  m_busy = true;
  const QJsonObject command = m_commands.isEmpty() ? QJsonObject() : m_commands.takeFirst();
  QNetworkRequest request(QUrl(network->apiBase()+"/downloads"));
  request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
  request.setTransferTimeout(10000);
  auto *reply = command.isEmpty() ? m_nam.get(request) : m_nam.post(request, QJsonDocument(command).toJson(QJsonDocument::Compact));
  network->prepareApiRequest(reply);
  connect(reply, &QNetworkReply::finished, this, [this, reply, command]() {
    m_busy = false;
    if (command.value("action").toString() == "enqueue")
      m_pendingTaskKeys.remove(taskKey(command.value("task").toObject()));
    BiliNetwork::instance()->observeApiReply(reply);
    const auto document = QJsonDocument::fromJson(reply->readAll());
    const auto object = document.object();
    if (reply->error() == QNetworkReply::NoError && object.value("code").toInt(-1) == 0) {
      m_error.clear(); applySnapshot(object.value("data").toObject());
      if (command.value("action").toString() == "enqueue") emit message(QStringLiteral("已加入下载队列"));
    } else {
      int code = reply->error();
      m_error = object.value("message").toString(reply->errorString());
      BiliNetwork::instance()->checkApiServerFailure(reply, code, m_error);
      if (!command.isEmpty()) emit message(m_error);
      emit queueChanged();
    }
    reply->deleteLater();
    if (!m_commands.isEmpty()) QTimer::singleShot(0, this, &BiliDownloadQueue::requestNext);
  });
}
void BiliDownloadQueue::applySnapshot(const QJsonObject &data) {
  m_error = data.value("error").toString();
  m_paused = data.value("paused").toBool();
  const auto tasks = data.value("tasks").toArray();
  for (int i = m_tasks.size()-1; i >= 0; --i) {
    bool present = false;
    for (const auto &task : tasks) if (task.toObject().value("id") == m_tasks[i].value("id")) { present = true; break; }
    if (!present) { beginRemoveRows({}, i, i); m_tasks.removeAt(i); endRemoveRows(); }
  }
  for (int i = 0; i < tasks.size(); ++i) {
    const auto task = tasks[i].toObject();
    if (i >= m_tasks.size() || m_tasks[i].value("id") != task.value("id")) {
      beginInsertRows({}, i, i); m_tasks.insert(i, task); endInsertRows();
    } else if (m_tasks[i] != task) { m_tasks[i] = task; emit dataChanged(index(i), index(i), {Qt::UserRole+1}); }
  }
  emit queueChanged();
}
