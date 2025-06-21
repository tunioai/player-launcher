# Google Play Publishing Checklist

Используйте этот чеклист для публикации приложения в Google Play Store.

## Подготовка к публикации

### ✅ 1. Keystore (Ключ подписи)
- [ ] Создан upload-keystore.jks файл
- [ ] Создан key.properties файл с корректными путями
- [ ] Пароли от keystore сохранены в безопасном месте
- [ ] key.properties добавлен в .gitignore

### ✅ 2. Версия приложения
- [ ] Обновлена версия в pubspec.yaml (например: 1.0.0+1)
- [ ] Номер версии больше предыдущей публикации

### ✅ 3. Тестирование
- [ ] Приложение протестировано в release режиме
- [ ] Проверена работа основных функций
- [ ] Протестирована работа на разных устройствах

## Сборка

### ✅ 4. Build
- [ ] Выполнена команда: `flutter clean`
- [ ] Выполнена команда: `flutter pub get`
- [ ] Собран AAB: `flutter build appbundle --release`
- [ ] Размер AAB меньше 150MB

## Google Play Console

### ✅ 5. App Information
- [ ] Название: "Tunio Player"
- [ ] Краткое описание (80 символов)
- [ ] Полное описание (4000 символов)
- [ ] Категория: "Music & Audio"

### ✅ 6. Graphics
- [ ] Иконка приложения (512x512 PNG)
- [ ] Скриншоты (минимум 2, рекомендуется 8)
- [ ] Feature Graphic (1024x500 PNG) - опционально

### ✅ 7. Store Listing
- [ ] Заполнен раздел "What's new" для первой версии
- [ ] Выбран подходящий Content Rating
- [ ] Указана Target Audience
- [ ] Добавлены контактные данные

### ✅ 8. App Permissions
Объяснения для разрешений:
- [ ] `INTERNET` - Для стриминга радио
- [ ] `ACCESS_NETWORK_STATE` - Проверка соединения
- [ ] `MODIFY_AUDIO_SETTINGS` - Управление громкостью
- [ ] `WAKE_LOCK` - Воспроизведение в фоне
- [ ] `FOREGROUND_SERVICE` - Фоновое воспроизведение
- [ ] `RECEIVE_BOOT_COMPLETED` - Автозапуск
- [ ] `SYSTEM_ALERT_WINDOW` - Совместимость с ТВ-приставками
- [ ] `START_FOREGROUND_SERVICES_FROM_BACKGROUND` - Фоновые сервисы на ТВ
- [ ] `USE_FULL_SCREEN_INTENT` - Полноэкранный режим

### ✅ 9. Privacy Policy
- [ ] Создана политика конфиденциальности (если собираются данные)
- [ ] Добавлена ссылка в Google Play Console

### ✅ 10. Pre-launch Report
- [ ] Проверен отчет pre-launch testing
- [ ] Исправлены критические ошибки (если есть)

## Финальная проверка

### ✅ 11. Release
- [ ] Загружен signed AAB файл
- [ ] Заполнены Release Notes
- [ ] Выбран правильный Release Type (Production)
- [ ] Проверены все обязательные поля

### ✅ 12. Submission
- [ ] Отправлено на модерацию
- [ ] Получено подтверждение отправки
- [ ] Ожидание результатов модерации (1-3 дня)

## После публикации

### ✅ 13. Post-release
- [ ] Проверена доступность в Google Play
- [ ] Протестирована установка из Store
- [ ] Мониторинг отзывов и рейтингов
- [ ] Подготовка к следующему обновлению

## Важные заметки

1. **Keystore безопасность**: Никогда не теряйте keystore файл и пароли! Без них невозможно обновить приложение.

2. **Version Code**: Каждое обновление должно иметь больший versionCode чем предыдущее.

3. **Тестирование**: Всегда тестируйте release build перед загрузкой.

4. **Permissions**: Будьте готовы объяснить каждое разрешение в описании приложения.

5. **Размер**: Google Play имеет ограничения на размер APK/AAB файлов.

## Команды для сборки

```bash
# Очистка проекта
flutter clean
flutter pub get

# Сборка release версии
flutter build appbundle --release

# Тестирование release версии
flutter install --release
```

## Полезные ссылки

- [Google Play Console](https://play.google.com/console)
- [Android App Bundle Guide](https://developer.android.com/guide/app-bundle)
- [Flutter Release Guide](https://docs.flutter.dev/deployment/android)
- [Google Play Policy](https://play.google.com/about/developer-content-policy/) 