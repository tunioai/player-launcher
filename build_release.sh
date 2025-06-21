#!/bin/bash

# Tunio Player - Release Build Script
# Этот скрипт автоматизирует процесс сборки release версии

set -e # Остановить выполнение при ошибке

echo "🚀 Начинаем сборку Tunio Player для Google Play"

# Проверяем наличие Flutter
if ! command -v flutter &> /dev/null; then
    echo "❌ Flutter не найден. Установите Flutter SDK."
    exit 1
fi

# Проверяем Android toolchain
echo "🔍 Проверяем Android toolchain..."
if ! flutter doctor | grep -q "Android toolchain.*✓"; then
    echo "⚠️  Обнаружены проблемы с Android toolchain."
    echo "Попробуем собрать с дополнительными флагами..."
    BUILD_FLAGS="--no-shrink"
else
    BUILD_FLAGS=""
fi

# Проверяем наличие key.properties
if [ ! -f "android/key.properties" ]; then
    echo "❌ Файл android/key.properties не найден!"
    echo "Создайте файл android/key.properties с содержимым:"
    echo "storePassword=your_store_password"
    echo "keyPassword=your_key_password"
    echo "keyAlias=upload"
    echo "storeFile=./upload-keystore.jks"
    exit 1
fi

# Очищаем проект
echo "🧹 Очищаем проект..."
flutter clean

# Устанавливаем зависимости
echo "📦 Устанавливаем зависимости..."
flutter pub get

# Проверяем конфигурацию
echo "🔍 Проверяем конфигурацию..."
flutter doctor

# Анализируем код
echo "🔍 Анализируем код..."
flutter analyze

# Запускаем тесты (если есть)
echo "🧪 Запускаем тесты..."
flutter test || echo "⚠️  Тесты не пройдены или отсутствуют"

# Собираем AAB
echo "🔨 Собираем Android App Bundle..."
if [ -n "$BUILD_FLAGS" ]; then
    echo "📝 Используем дополнительные флаги: $BUILD_FLAGS"
    flutter build appbundle --release $BUILD_FLAGS
else
    flutter build appbundle --release
fi

# Проверяем размер файла
AAB_FILE="build/app/outputs/bundle/release/app-release.aab"
if [ -f "$AAB_FILE" ]; then
    FILE_SIZE=$(ls -lh "$AAB_FILE" | awk '{print $5}')
    echo "✅ AAB файл успешно создан: $AAB_FILE"
    echo "📏 Размер файла: $FILE_SIZE"
    
    # Проверяем размер (предупреждение если больше 100MB)
    FILE_SIZE_BYTES=$(stat -c%s "$AAB_FILE" 2>/dev/null || stat -f%z "$AAB_FILE" 2>/dev/null)
    if [ "$FILE_SIZE_BYTES" -gt 104857600 ]; then
        echo "⚠️  Предупреждение: Размер файла больше 100MB"
    fi
else
    echo "❌ Ошибка: AAB файл не создан"
    exit 1
fi

# Также собираем APK для тестирования
echo "🔨 Собираем APK для тестирования..."
if [ -n "$BUILD_FLAGS" ]; then
    flutter build apk --release $BUILD_FLAGS
else
    flutter build apk --release
fi

APK_FILE="build/app/outputs/flutter-apk/app-release.apk"
if [ -f "$APK_FILE" ]; then
    APK_SIZE=$(ls -lh "$APK_FILE" | awk '{print $5}')
    echo "✅ APK файл создан: $APK_FILE"
    echo "📏 Размер APK: $APK_SIZE"
fi

echo ""
echo "🎉 Сборка завершена успешно!"
echo ""
echo "📁 Файлы для загрузки:"
echo "   AAB (для Google Play): $AAB_FILE"
echo "   APK (для тестирования): $APK_FILE"
echo ""
echo "📋 Следующие шаги:"
echo "1. Протестируйте APK: flutter install --release"
echo "2. Загрузите AAB в Google Play Console"
echo "3. Заполните описание приложения"
echo "4. Отправьте на модерацию"
echo ""
echo "📖 Подробная инструкция в README.md и PUBLISH_CHECKLIST.md" 

adb install -r build/app/outputs/flutter-apk/app-release.apk
