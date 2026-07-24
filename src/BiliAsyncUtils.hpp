#pragma once

#include <QMetaObject>
#include <QObject>
#include <QPointer>
#include <QRunnable>
#include <QThreadPool>
#include <type_traits>
#include <utility>

template <typename Work, typename Apply>
void biliRunInWorker(QObject *context, Work &&work, Apply &&apply) {
  using WorkFn = std::decay_t<Work>;
  using ApplyFn = std::decay_t<Apply>;
  using Result = std::decay_t<decltype(std::declval<WorkFn &>()())>;

  class Task final : public QRunnable {
  public:
    Task(QPointer<QObject> guard, WorkFn workFn, ApplyFn applyFn)
        : m_guard(std::move(guard)), m_work(std::move(workFn)),
          m_apply(std::move(applyFn)) {}

    void run() override {
      Result result = m_work();
      QObject *target = m_guard;
      if (!target)
        return;

      auto guard = m_guard;
      auto applyFn = std::move(m_apply);
      QMetaObject::invokeMethod(
          target,
          [guard, result = std::move(result), applyFn = std::move(applyFn)]()
              mutable {
                if (!guard)
                  return;
                applyFn(std::move(result));
              },
          Qt::QueuedConnection);
    }

  private:
    QPointer<QObject> m_guard;
    WorkFn m_work;
    ApplyFn m_apply;
  };

  QThreadPool::globalInstance()->start(new Task(QPointer<QObject>(context),
                                               std::forward<Work>(work),
                                               std::forward<Apply>(apply)));
}
