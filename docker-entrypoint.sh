#!/bin/bash
set -e

# get postgres infomartion from DATABASE_URL
clean_url="${DATABASE_URL//\'}"
proto="$(echo $clean_url | grep :// | sed -e's,^\(.*://\).*,\1,g')"
url="$(echo ${clean_url/$proto/})"
user_pass="$(echo $url | grep @ | cut -d@ -f1)"
POSTGRES_ENV_POSTGRES_PASSWORD="$(echo $user_pass | cut -d: -f2)"
POSTGRES_ENV_POSTGRES_USER="$(echo ${user_pass/:$POSTGRES_ENV_POSTGRES_PASSWORD})"
host_port="$(echo ${url/$user_pass@/} | cut -d/ -f1)"
POSTGRES_PORT_5432_TCP="$(echo $host_port | sed -e 's,^.*:,:,g' -e 's,.*:\([0-9]*\).*,\1,g' -e 's,[^0-9],,g')"
POSTGRES_ENV_POSTGRES_DB="$(echo $url | grep / | cut -d/ -f2-)"

if [[ "$1" == apache2* ]] || [ "$1" == php-fpm ]; then
	: "${WORDPRESS_DB_HOST:=postgres}"
	# if we're linked to PostgresSQL and thus have credentials already, let's use them
	: ${WORDPRESS_DB_USER:=${POSTGRES_ENV_POSTGRES_USER:-postgres}}
	if [ "$WORDPRESS_DB_USER" = 'postgres' ]; then
		: ${WORDPRESS_DB_PASSWORD:=$POSTGRES_ENV_POSTGRES_PASSWORD}
	fi
	: ${WORDPRESS_DB_PASSWORD:=$POSTGRES_ENV_POSTGRES_PASSWORD}
	: ${WORDPRESS_DB_NAME:=${POSTGRES_ENV_POSTGRES_DB:-wordpress}}

	if [ -z "$WORDPRESS_DB_PASSWORD" ]; then
		echo >&2 'error: missing required WORDPRESS_DB_PASSWORD environment variable'
		echo >&2 '  Did you forget to -e WORDPRESS_DB_PASSWORD=... ?'
		echo >&2
		echo >&2 '  (Also of interest might be WORDPRESS_DB_USER and WORDPRESS_DB_NAME.)'
		exit 1
	fi

	if ! [ -e index.php -a -e wp-includes/version.php ]; then
		echo >&2 "WordPress not found in $(pwd) - copying now..."
		if [ "$(ls -A)" ]; then
			echo >&2 "WARNING: $(pwd) is not empty - press Ctrl+C now if this is an error!"
			( set -x; ls -A; sleep 10 )
		fi
		tar cf - --one-file-system -C /usr/src/wordpress . | tar xf -
		echo >&2 "Complete! WordPress has been successfully copied to $(pwd)"
		if [ ! -e .htaccess ]; then
			# NOTE: The "Indexes" option is disabled in the php:apache base image
			cat > .htaccess <<-'EOF'
				# BEGIN WordPress
				<IfModule mod_rewrite.c>
				RewriteEngine On
				RewriteBase /
				RewriteRule ^index\.php$ - [L]
				RewriteCond %{REQUEST_FILENAME} !-f
				RewriteCond %{REQUEST_FILENAME} !-d
				RewriteRule . /index.php [L]
				</IfModule>
				# END WordPress
			EOF
			chown www-data:www-data .htaccess
		fi
	fi

	# TODO handle WordPress upgrades magically in the same way, but only if wp-includes/version.php's $wp_version is less than /usr/src/wordpress/wp-includes/version.php's $wp_version

	# version 4.4.1 decided to switch to windows line endings, that breaks our seds and awks
	# https://github.com/docker-library/wordpress/issues/116
	# https://github.com/WordPress/WordPress/commit/1acedc542fba2482bab88ec70d4bea4b997a92e4
	sed -ri -e 's/\r\n|\r/\n/g' wp-config*

	if [ ! -e wp-config.php ]; then
		awk '/^\/\*.*stop editing.*\*\/$/ && c == 0 { c = 1; system("cat") } { print }' wp-config-sample.php > wp-config.php <<'EOPHP'
// If we're behind a proxy server and using HTTPS, we need to alert Wordpress of that fact
// see also http://codex.wordpress.org/Administration_Over_SSL#Using_a_Reverse_Proxy
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
	$_SERVER['HTTPS'] = 'on';
}
EOPHP
		chown www-data:www-data wp-config.php
	fi

	# see http://stackoverflow.com/a/2705678/433558
	sed_escape_lhs() {
		echo "$@" | sed -e 's/[]\/$*.^|[]/\\&/g'
	}
	sed_escape_rhs() {
		echo "$@" | sed -e 's/[\/&]/\\&/g'
	}
	php_escape() {
		php -r 'var_export(('$2') $argv[1]);' -- "$1"
	}
	set_config() {
		key="$1"
		value="$2"
		var_type="${3:-string}"
		start="(['\"])$(sed_escape_lhs "$key")\2\s*,"
		end="\);"
		if [ "${key:0:1}" = '$' ]; then
			start="^(\s*)$(sed_escape_lhs "$key")\s*="
			end=";"
		fi
		sed -ri -e "s/($start\s*).*($end)$/\1$(sed_escape_rhs "$(php_escape "$value" "$var_type")")\3/" wp-config.php
	}

	set_config 'DB_HOST' "$WORDPRESS_DB_HOST"
	set_config 'DB_USER' "$WORDPRESS_DB_USER"
	set_config 'DB_PASSWORD' "$WORDPRESS_DB_PASSWORD"
	set_config 'DB_NAME' "$WORDPRESS_DB_NAME"

	# allow any of these "Authentication Unique Keys and Salts." to be specified via
	# environment variables with a "WORDPRESS_" prefix (ie, "WORDPRESS_AUTH_KEY")
	UNIQUES=(
		AUTH_KEY
		SECURE_AUTH_KEY
		LOGGED_IN_KEY
		NONCE_KEY
		AUTH_SALT
		SECURE_AUTH_SALT
		LOGGED_IN_SALT
		NONCE_SALT
	)
	for unique in "${UNIQUES[@]}"; do
		eval unique_value=\$WORDPRESS_$unique
		if [ "$unique_value" ]; then
			set_config "$unique" "$unique_value"
		else
			# if not specified, let's generate a random value
			current_set="$(sed -rn -e "s/define\((([\'\"])$unique\2\s*,\s*)(['\"])(.*)\3\);/\4/p" wp-config.php)"
			if [ "$current_set" = 'put your unique phrase here' ]; then
				set_config "$unique" "$(head -c1M /dev/urandom | sha1sum | cut -d' ' -f1)"
			fi
		fi
	done

	if [ "$WORDPRESS_TABLE_PREFIX" ]; then
		set_config '$table_prefix' "$WORDPRESS_TABLE_PREFIX"
	fi

	if [ "$WORDPRESS_DEBUG" ]; then
		set_config 'WP_DEBUG' 1 boolean
	fi

	TERM=dumb php -- "$WORDPRESS_DB_HOST" "$POSTGRES_PORT_5432_TCP" "$WORDPRESS_DB_USER" "$WORDPRESS_DB_PASSWORD" "$WORDPRESS_DB_NAME" <<'EOPHP'
<?php
// database might not exist, so let's try creating it (just to be safe)
$host=$argv[1];
$port=$argv[2];
$dbuser=$argv[3];
$dbpass=$argv[4];
$dbname=$argv[5];
$maxTries = 10;

while ($maxTries > 0)
{
	try {
		$pdo = new PDO("pgsql:host=$host;port=$port;dbname=$dbname", $dbuser, $dbpass);
		// Postgres version of "CREATE DATABASE IF NOT EXISTS"
		$res = $pdo->query("select count(*) from pg_catalog.pg_database where datname = '$dbname';");
		if($res->fetchColumn() < 1)
			$pdo->query("CREATE DATABASE $dbname");

		$maxTries = 0;
	} catch (PDOException $e) {
		echo $e;
		$maxTries--;
		sleep(3);
	}
}
EOPHP
fi

exec "$@"