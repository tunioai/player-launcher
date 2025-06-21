# Настройка GitHub Actions для автоматической сборки

## Обзор

GitHub Actions настроены для автоматической сборки приложения при каждом релизе. Система создает сборки для Android и macOS, а затем автоматически создает релиз с артефактами.

## Workflows

1. **`ci.yml`** - Проверка кода при push/PR
2. **`release.yml`** - Создание релизов при пуше тега

## Настройка Secrets

Для работы автоматической сборки нужно настроить следующие секреты в GitHub:

### Переход в настройки секретов:
1. Перейдите в репозиторий на GitHub
2. Settings → Secrets and variables → Actions
3. Нажмите "New repository secret"

### Необходимые секреты:

#### 1. `ANDROID_KEYSTORE`
```bash
# Конвертируйте ваш keystore в base64
base64 -i android/app/upload-keystore.jks | pbcopy
```
Вставьте результат в секрет `ANDROID_KEYSTORE`

#### 2. `KEYSTORE_PASSWORD`
Пароль от keystore файла

#### 3. `KEY_PASSWORD`
Пароль от ключа

#### 4. `KEY_ALIAS`
Псевдоним ключа (обычно "upload")

## Как создать релиз

### 1. Обновите версию в pubspec.yaml
```yaml
version: 1.0.1+7  # Увеличьте версию
```

### 2. Создайте и запушьте тег
```bash
# Создать тег
git tag v1.0.1

# Запушить тег
git push origin v1.0.1
```

### 3. Автоматическая сборка
GitHub Actions автоматически:
- Соберет APK и AAB для Android
- Соберет приложение для macOS
- Создаст релиз с файлами для скачивания
- Добавит описание релиза

## Структура релиза

Каждый релиз будет содержать:
- `app-release.aab` - для загрузки в Google Play
- `app-release.apk` - для тестирования/прямой установки
- `tunio-player-macos.tar.gz` - macOS приложение

## Преимущества

✅ **Автоматизация** - нет необходимости в ручной сборке
✅ **Консистентность** - одинаковая среда сборки
✅ **Безопасность** - ключи хранятся в GitHub Secrets
✅ **Мультиплатформенность** - Android и macOS одновременно
✅ **Артефакты** - автоматическое создание релизов

## Мониторинг

Вы можете отслеживать процесс сборки:
1. Перейдите на вкладку "Actions" в репозитории
2. Выберите нужный workflow
3. Смотрите прогресс в реальном времени

## Устранение проблем

### Проблема с keystore
Если сборка не удается из-за keystore:
1. Убедитесь, что keystore файл существует
2. Проверьте, что все секреты заполнены
3. Убедитесь, что base64 конвертация выполнена правильно

### Проблема с версией Flutter
Если нужна другая версия Flutter, измените в workflows:
```yaml
- name: Setup Flutter
  uses: subosito/flutter-action@v2
  with:
    flutter-version: '3.24.3'  # Измените версию
    channel: 'stable'
```

### Проблема с зависимостями
Если сборка не удается из-за зависимостей:
1. Проверьте, что все зависимости совместимы
2. Убедитесь, что pubspec.yaml корректен
3. Проверьте лог ошибок в Actions

## Команды для локальной проверки

```bash
# Проверить форматирование
flutter format lib/ test/

# Анализ кода
flutter analyze

# Запустить тесты
flutter test

# Локальная сборка
flutter build apk --release
flutter build appbundle --release
```

## Альтернативы

Если GitHub Actions не подходит, рассмотрите:
- **Codemagic** - специализированная CI/CD для Flutter
- **GitLab CI** - если используете GitLab
- **Bitrise** - мобильная CI/CD платформа

## Дополнительные возможности

### Автоматическая загрузка в Google Play
Можно добавить автоматическую загрузку в Google Play Console:
```yaml
- name: Upload to Google Play
  uses: r0adkll/upload-google-play@v1
  with:
    serviceAccountJsonPlainText: ${{ secrets.GOOGLE_PLAY_SERVICE_ACCOUNT }}
    packageName: ai.tunio.radioplayer
    releaseFiles: build/app/outputs/bundle/release/app-release.aab
    track: production
```

### Уведомления
Можно добавить уведомления в Slack/Discord/Telegram при успешной сборке.

### Тестирование
Можно добавить более продвинутые тесты, интеграционные тесты и т.д.

---

**Готово!** Теперь каждый раз, когда вы пушите тег, GitHub Actions автоматически создаст релиз с готовыми для загрузки файлами. 