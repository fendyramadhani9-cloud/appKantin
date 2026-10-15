FROM trafex/php-nginx
COPY --chown=nobody . /var/www/html/
