# Быстрый старт: Публикация в Google Play

## 1. Создайте keystore файл

```bash
keytool -genkey -v -keystore ~/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

**Сохраните пароли!** Они понадобятся для всех будущих обновлений.

## 2. Настройте подпись

```bash
# Скопируйте пример файла
cp android/key.properties.example android/key.properties

# Отредактируйте android/key.properties своими данными
nano android/key.properties
```

## 3. Соберите приложение

```bash
# Используйте готовый скрипт
./build_release.sh

# Или вручную:
flutter clean
flutter pub get
flutter build appbundle --release
```

## 4. Найдите готовый файл

Файл для загрузки в Google Play:
```
build/app/outputs/bundle/release/app-release.aab
```

## 5. Загрузите в Google Play Console

1. Перейдите на https://play.google.com/console
2. Создайте новое приложение или выберите существующее
3. Загрузите AAB файл
4. Заполните описание и скриншоты
5. Отправьте на модерацию

## Готово! 🎉

Подробные инструкции смотрите в:
- `README.md` - полное руководство
- `PUBLISH_CHECKLIST.md` - чеклист для публикации 