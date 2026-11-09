#pragma once

#include <QAbstractListModel>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QTimer>
#include <QSet>
#include <QVector>

// UI adapter only. The Go worker and its durable queue survive every QML page.
class BiliDownloadQueue : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(bool paused READ paused NOTIFY queueChanged)
  Q_PROPERTY(int count READ count NOTIFY queueChanged)
  Q_PROPERTY(int completedCount READ completedCount NOTIFY queueChanged)
  Q_PROPERTY(QString error READ error NOTIFY queueChanged)
public:
  static BiliDownloadQueue *instance();
  static void destroyInstance();
  int rowCount(const QModelIndex &parent = QModelIndex()) const override;
  QVariant data(const QModelIndex &index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;
  bool paused() const { return m_paused; }
  int count() const { return m_tasks.size(); }
  int completedCount() const;
  QString error() const { return m_error; }
  void enqueue(const QJsonObject &task);
  Q_INVOKABLE void pauseAll();
  Q_INVOKABLE void startAll();
  Q_INVOKABLE void clearCompleted();
  Q_INVOKABLE void pauseTask(const QString &id);
  Q_INVOKABLE void resumeTask(const QString &id);
  Q_INVOKABLE void remove(const QString &id);
  Q_INVOKABLE void refresh();
signals:
  void queueChanged();
  void message(const QString &text);
private:
  explicit BiliDownloadQueue(QObject *parent = nullptr);
  bool command(const QString &action, const QJsonObject &extra = {});
  void requestNext();
  void applySnapshot(const QJsonObject &data);
  static BiliDownloadQueue *s_instance;
  QNetworkAccessManager m_nam;
  QTimer m_poll;
  QVector<QJsonObject> m_tasks;
  QVector<QJsonObject> m_commands;
  QSet<QString> m_pendingTaskKeys;
  bool m_paused = false;
  bool m_busy = false;
  QString m_error;
};
