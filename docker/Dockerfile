# SmartTunes image: PHP 8.3 + Apache serving the legacy PHP app.
# Build from the repository root:
#   docker build -f docker/Dockerfile --build-arg APP_VERSION=<git-sha> -t <repo>:<git-sha> .
FROM php:8.3-apache

# Baked into the image so every running container can report which commit it is.
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

# mysqli is the only extension not bundled with the official image
# (curl, fileinfo and openssl are already compiled in).
# rewrite: the app's .htaccess routes old URLs; headers: X-App-Version header.
RUN docker-php-ext-install mysqli \
    && a2enmod rewrite headers \
    && mkdir -p /var/lib/php/sessions \
    && chown www-data:www-data /var/lib/php/sessions

COPY docker/smarttunes.ini /usr/local/etc/php/conf.d/smarttunes.ini
COPY docker/apache-smarttunes.conf /etc/apache2/conf-enabled/smarttunes.conf

# App code. www-data must be able to write the recording staging folders.
COPY --chown=www-data:www-data app/ /var/www/html/
COPY --chown=www-data:www-data docker/healthz.php /var/www/html/healthz.php

# Docker marks the container unhealthy if the app or its database stops answering.
HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS http://localhost/healthz.php > /dev/null || exit 1
