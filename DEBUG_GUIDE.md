# Tunio Radio App - Debug Guide

## Проблема зависания "Loading..."

Данное руководство поможет диагностировать проблему, когда приложение показывает статус "Loading...", есть пинг (например, 76ms), WiFi работает ("OK"), но буфер = 0 и воспроизведение не начинается.

## Новые дебаг-логи

В приложение добавлены подробные логи с префиксами для каждого компонента:

- `🔄 API_DEBUG` - API запросы и ответы
- `🎵 AUDIO_DEBUG` - Аудио воспроизведение
- `🎵 STATE_DEBUG` - Смена состояний аудио плеера
- `📊 BUFFER_DEBUG` - Буферизация данных
- `🌐 NET_DEBUG` - Проверка подключения
- `🌐 PING_DEBUG` - Измерение пинга
- `🎛️ CONTROLLER_DEBUG` - Контроллер радио
- `🔗 ATTEMPT_DEBUG` - Попытки подключения
- `🔄 RECONNECT_DEBUG` - Переподключения
- `🎛️ TIMEOUT_DEBUG` - Таймауты
- `🎛️ HEALTH_DEBUG` - Проверка здоровья стрима
- `🩺 DIAGNOSTIC_*` - Диагностическая информация

## Как использовать

### Вариант 1: Быстрый скрипт (рекомендуется)

```bash
./debug_logs.sh
```

Скрипт предложит выбрать тип логов для просмотра:
- Вариант 8 - мониторинг в реальном времени
- Вариант 0 - очистить логи и начать новый мониторинг

### Вариант 2: Прямые команды adb

```bash
# Показать все дебаг логи
adb logcat -s "flutter" | grep -E "(API_DEBUG|AUDIO_DEBUG|NET_DEBUG|CONTROLLER_DEBUG|BUFFER_DEBUG|STATE_DEBUG|PING_DEBUG|ATTEMPT_DEBUG|TIMEOUT_DEBUG|RECONNECT_DEBUG|DIAGNOSTIC_|HEALTH_DEBUG)"

# Мониторинг критических ошибок
adb logcat -s "flutter" | grep -E "(ERROR|CRITICAL|ZERO BUFFER|Stream stuck|Timeout|Failed)"

# Только буфер (для проблемы буфер = 0)
adb logcat -s "flutter" | grep "BUFFER_DEBUG"
```

## Диагностика проблемы зависания

### Шаг 1: Воспроизведение проблемы

1. Запустите мониторинг логов:
   ```bash
   ./debug_logs.sh
   # Выберите вариант 8 (live monitoring)
   ```

2. В приложении введите код и подключитесь
3. Дождитесь появления статуса "Loading..." с зависанием

### Шаг 2: Ключевые индикаторы

Ищите в логах следующие паттерны:

#### Нормальный процесс подключения:
```
🔄 API_DEBUG: Starting API request...
🔄 API_DEBUG: HTTP request completed in Xms
🎵 AUDIO_DEBUG: About to set audio source...
🎵 STATE_DEBUG: LOADING state detected
🎵 STATE_DEBUG: PLAYING state detected
```

#### Проблемы с API:
```
🔄 API_DEBUG: Timeout exception during API call
🔄 API_DEBUG: HTTP client exception
```

#### Проблемы с аудио:
```
🎵 AUDIO_DEBUG: Error in playStream
🎵 STATE_DEBUG: Stream stuck in LOADING
🚨 BUFFER_DEBUG: ZERO BUFFER detected!
```

#### Проблемы с сетью:
```
🌐 NET_DEBUG: Connectivity check failed
🌐 PING_DEBUG: HIGH PING detected
```

### Шаг 3: Диагностический дамп

Каждые 30 секунд система автоматически логирует полное состояние:

```
🩺 DIAGNOSTIC_HEALTH_CHECK: === SYSTEM STATE DUMP ===
🩺 DIAGNOSTIC_HEALTH_CHECK: Audio State: AudioState.loading
🩺 DIAGNOSTIC_HEALTH_CHECK: Network State: CONNECTED
🩺 DIAGNOSTIC_HEALTH_CHECK: Buffer: 0s
```

### Шаг 4: Критические алерты

Система автоматически обнаружит проблемы:

```
🎛️ HEALTH_DEBUG: Stream stuck in AudioState.loading for over 2 minutes!
🎛️ HEALTH_DEBUG: This is likely the hanging issue we are debugging
```

## Известные паттерны проблем

### 1. Буфер = 0 и зависание
```
🚨 BUFFER_DEBUG: ZERO BUFFER detected!
🎵 STATE_DEBUG: LOADING state detected - stream is connecting
```
**Причина**: Аудио плеер не может загрузить данные со стрима

### 2. API успешен, но аудио не стартует
```
🔄 API_DEBUG: API call completed successfully
🎵 AUDIO_DEBUG: Error in playStream: [error details]
```
**Причина**: Проблема с аудио потоком или его форматом

### 3. Сеть OK, но нет данных
```
🌐 NET_DEBUG: Connectivity result: true
🌐 PING_DEBUG: Ping measurement: 76ms
🚨 BUFFER_DEBUG: ZERO BUFFER detected!
```
**Причина**: Проблема с аудио сервером или URL

## Сбор информации для багрепорта

Когда проблема воспроизводится, сохраните логи:

```bash
# Сохранить все логи в файл
adb logcat -s "flutter" > debug_full.log

# Сохранить только критические события
adb logcat -s "flutter" | grep -E "(ERROR|CRITICAL|ZERO BUFFER|Stream stuck)" > debug_critical.log
```

## Полезные команды

```bash
# Очистить логи перед тестом
adb logcat -c

# Показать только последние 100 строк
adb logcat -s "flutter" -t 100

# Фильтровать по времени (последние 10 минут)
adb logcat -s "flutter" -t '10 minutes ago'
```

## Быстрая диагностика

Если приложение зависло в "Loading...":

1. Запустите: `./debug_logs.sh` (выбор 9 - критические ошибки)
2. Ищите сообщения с `ZERO BUFFER` или `Stream stuck`
3. Проверьте последние `API_DEBUG` логи на ошибки
4. Посмотрите `NET_DEBUG` для проблем с сетью

Эта информация поможет точно определить причину зависания. 