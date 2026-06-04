#!/bin/bash

# ============================================================================
# LibreNMS Installation Script - Enterprise Edition
# Versión: 2.0.0
# Descripción: Instalación automatizada y segura de LibreNMS
# Autor: Optimizado para entorno empresarial
# ============================================================================

set -euo pipefail

# ============================================================================
# CONFIGURACIÓN GLOBAL
# ============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/librenms-install-$(date +%Y%m%d_%H%M%S).log"
readonly BACKUP_DIR="/var/backups/librenms-$(date +%Y%m%d_%H%M%S)"

# Colores para output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Variables de configuración (se pueden sobrescribir con variables de entorno)
export LIBRENMS_DB_PASSWORD="${LIBRENMS_DB_PASSWORD:-}"
export LIBRENMS_DB_NAME="${LIBRENMS_DB_NAME:-librenms}"
export LIBRENMS_DB_USER="${LIBRENMS_DB_USER:-librenms}"
export WEB_HOSTNAME="${WEB_HOSTNAME:-}"
export SNMP_COMMUNITY="${SNMP_COMMUNITY:-ChangeMe_SecureCommunity_2026}"
export SYSLOG_ENABLED="${SYSLOG_ENABLED:-true}"

# ============================================================================
# FUNCIONES DE LOGGING Y UTILIDADES
# ============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")    echo -e "${BLUE}[INFO]${NC} $message" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
        "WARNING") echo -e "${YELLOW}[WARNING]${NC} $message" ;;
        "ERROR")   echo -e "${RED}[ERROR]${NC} $message" ;;
    esac
    
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

log_info()    { log "INFO" "$@"; }
log_success() { log "SUCCESS" "$@"; }
log_warning() { log "WARNING" "$@"; }
log_error()   { log "ERROR" "$@"; }

error_exit() {
    log_error "$1"
    log_error "Revisa el log completo en: $LOG_FILE"
    exit 1
}

# ============================================================================
# FUNCIONES DE VALIDACIÓN
# ============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "Este script debe ejecutarse como root (usa sudo)"
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error_exit "No se puede detectar el sistema operativo"
    fi
    
    source /etc/os-release
    
    case "$ID" in
        ubuntu|debian)
            log_info "Sistema operativo detectado: $PRETTY_NAME"
            ;;
        *)
            error_exit "Sistema operativo no soportado: $ID. Solo Ubuntu y Debian están soportados."
            ;;
    esac
}

check_internet() {
    log_info "Verificando conectividad a internet..."
    if ! ping -c 1 github.com &> /dev/null; then
        error_exit "No hay conectividad a internet. Verifica tu conexión."
    fi
    log_success "Conectividad a internet verificada"
}

check_disk_space() {
    log_info "Verificando espacio en disco..."
    local required_gb=5
    local available_gb=$(df -BG /opt | tail -1 | awk '{print $4}' | sed 's/G//')
    
    if [[ $available_gb -lt $required_gb ]]; then
        error_exit "Espacio insuficiente en /opt. Necesitas al menos ${required_gb}GB, tienes ${available_gb}GB"
    fi
    log_success "Espacio en disco suficiente: ${available_gb}GB disponible"
}

validate_inputs() {
    log_info "Validando parámetros de entrada..."
    
    # Solicitar contraseña si no está definida
    if [[ -z "$LIBRENMS_DB_PASSWORD" ]]; then
        while true; do
            read -sp "Ingresa la contraseña para la base de datos de LibreNMS: " LIBRENMS_DB_PASSWORD
            echo
            if [[ ${#LIBRENMS_DB_PASSWORD} -lt 12 ]]; then
                log_warning "La contraseña debe tener al menos 12 caracteres"
                continue
            fi
            read -sp "Confirma la contraseña: " LIBRENMS_DB_PASSWORD_CONFIRM
            echo
            if [[ "$LIBRENMS_DB_PASSWORD" != "$LIBRENMS_DB_PASSWORD_CONFIRM" ]]; then
                log_warning "Las contraseñas no coinciden"
                continue
            fi
            break
        done
        export LIBRENMS_DB_PASSWORD
    fi
    
    # Solicitar hostname si no está definido
    if [[ -z "$WEB_HOSTNAME" ]]; then
        read -p "Ingresa el hostname o IP del servidor web (ej: librenms.empresa.local): " WEB_HOSTNAME
        if [[ -z "$WEB_HOSTNAME" ]]; then
            error_exit "El hostname no puede estar vacío"
        fi
        export WEB_HOSTNAME
    fi
    
    log_success "Parámetros validados correctamente"
}

# ============================================================================
# FUNCIONES DE BACKUP
# ============================================================================

create_backup() {
    log_info "Creando backup de configuraciones existentes..."
    mkdir -p "$BACKUP_DIR"
    
    # Backup de configuraciones si existen
    [[ -f /etc/nginx/conf.d/librenms.conf ]] && cp /etc/nginx/conf.d/librenms.conf "$BACKUP_DIR/" 2>/dev/null || true
    [[ -f /etc/mysql/mariadb.conf.d/50-server.cnf ]] && cp /etc/mysql/mariadb.conf.d/50-server.cnf "$BACKUP_DIR/" 2>/dev/null || true
    [[ -d /opt/librenms ]] && mysqldump -u root "$LIBRENMS_DB_NAME" > "$BACKUP_DIR/librenms-db-backup.sql" 2>/dev/null || true
    
    log_success "Backup creado en: $BACKUP_DIR"
}

# ============================================================================
# FUNCIONES DE DETECCIÓN DINÁMICA
# ============================================================================

detect_php_version() {
    log_info "Detectando versión de PHP..."
    
    # Intentar obtener versión de PHP si ya está instalado
    if command -v php &> /dev/null; then
        PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")
    fi
    
    # Si no está instalado, detectar según la versión del SO
    if [[ -z "$PHP_VER" ]]; then
        source /etc/os-release
        case "$VERSION_ID" in
            "24.04"|"24.10") PHP_VER="8.3" ;;
            "22.04") PHP_VER="8.1" ;;
            "20.04") PHP_VER="7.4" ;;
            "12") PHP_VER="8.2" ;;  # Debian 12
            "11") PHP_VER="7.4" ;;  # Debian 11
            *) PHP_VER="8.3" ;;     # Default
        esac
    fi
    
    log_success "Versión de PHP detectada: $PHP_VER"
    export PHP_VER
}

detect_timezone() {
    log_info "Detectando zona horaria del sistema..."
    SYS_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")
    log_success "Zona horaria detectada: $SYS_TZ"
    export SYS_TZ
}

# ============================================================================
# FUNCIONES DE ESCAPE DE CONTRASEÑAS
# ============================================================================

escape_password_sql() {
    # Escapar comillas simples para SQL (duplicarlas)
    local password="$1"
    echo "${password//\'/\'\'}"
}

escape_password_sed() {
    # Escapar caracteres especiales para sed (/ & \)
    local password="$1"
    printf '%s\n' "$password" | sed -e 's/[\/&]/\\&/g'
}

# ============================================================================
# FUNCIONES DE INSTALACIÓN
# ============================================================================

install_packages() {
    log_info "Instalando paquetes requeridos..."
    
    apt-get update -qq
    
    apt-get install -y -qq \
        acl curl fping git graphviz imagemagick \
        mariadb-client mariadb-server \
        mtr-tiny nginx-full \
        nmap \
        php-cli php-curl php-fpm php-gd php-gmp php-json php-mbstring php-mysql \
        php-snmp php-xml php-zip \
        rrdtool snmp snmpd \
        unzip \
        python3-command-runner python3-pymysql python3-dotenv python3-redis \
        python3-setuptools python3-psutil python3-systemd python3-pip \
        whois traceroute iputils-ping tcpdump vim cron \
        ufw
    
    log_success "Paquetes instalados correctamente"
}

create_librenms_user() {
    log_info "Creando usuario librenms..."
    
    if id -u librenms &>/dev/null; then
        log_info "Usuario librenms ya existe, omitiendo creación"
    else
        useradd librenms -d /opt/librenms -M -r -s "$(which bash)"
        log_success "Usuario librenms creado"
    fi
}

clone_repository() {
    log_info "Clonando repositorio de LibreNMS..."
    
    if [[ -d "/opt/librenms" ]]; then
        log_info "LibreNMS ya existe, actualizando..."
        cd /opt/librenms
        sudo -u librenms git pull || log_warning "No se pudo actualizar, continuando con versión existente"
    else
        git clone https://github.com/librenms/librenms.git /opt/librenms
        log_success "Repositorio clonado correctamente"
    fi
}

set_permissions() {
    log_info "Configurando permisos..."
    
    chown -R librenms:librenms /opt/librenms
    chmod 771 /opt/librenms
    setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
    setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
    
    log_success "Permisos configurados correctamente"
}

install_composer() {
    log_info "Instalando dependencias de Composer..."
    
    sudo -u librenms /opt/librenms/scripts/composer_wrapper.php install --no-dev
    
    log_success "Dependencias de Composer instaladas"
}

configure_php_timezone() {
    log_info "Configurando zona horaria en PHP..."
    
    # Configurar PHP-FPM
    if [[ -f /etc/php/$PHP_VER/fpm/php.ini ]]; then
        sed -i "s/;date.timezone =.*/date.timezone = $SYS_TZ/" /etc/php/$PHP_VER/fpm/php.ini
        sed -i "s/date.timezone =.*/date.timezone = $SYS_TZ/" /etc/php/$PHP_VER/fpm/php.ini
    fi
    
    # Configurar PHP-CLI
    if [[ -f /etc/php/$PHP_VER/cli/php.ini ]]; then
        sed -i "s/;date.timezone =.*/date.timezone = $SYS_TZ/" /etc/php/$PHP_VER/cli/php.ini
        sed -i "s/date.timezone =.*/date.timezone = $SYS_TZ/" /etc/php/$PHP_VER/cli/php.ini
    fi
    
    # Configurar zona horaria del sistema
    timedatectl set-timezone "$SYS_TZ"
    
    log_success "Zona horaria configurada: $SYS_TZ"
}

configure_mariadb() {
    log_info "Configurando MariaDB..."
    
    # Agregar configuración optimizada solo si no existe
    if ! grep -q "innodb_file_per_table=1" /etc/mysql/mariadb.conf.d/50-server.cnf; then
        cat >> /etc/mysql/mariadb.conf.d/50-server.cnf <<EOF

# Optimizaciones para LibreNMS
innodb_file_per_table=1
lower_case_table_names=0
max_allowed_packet=128M
max_connections=200
EOF
        log_success "Configuración de MariaDB optimizada"
    else
        log_info "Configuración de MariaDB ya existe"
    fi
    
    systemctl enable mariadb
    systemctl restart mariadb
    
    log_success "MariaDB configurado y reiniciado"
}

create_database() {
    log_info "Creando base de datos y usuario..."
    
    local escaped_pass=$(escape_password_sql "$LIBRENMS_DB_PASSWORD")
    
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS $LIBRENMS_DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$LIBRENMS_DB_USER'@'localhost' IDENTIFIED BY '$escaped_pass';
GRANT ALL PRIVILEGES ON $LIBRENMS_DB_NAME.* TO '$LIBRENMS_DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
    
    log_success "Base de datos y usuario creados"
}

configure_php_fpm() {
    log_info "Configurando PHP-FPM pool..."
    
    cp /etc/php/$PHP_VER/fpm/pool.d/www.conf /etc/php/$PHP_VER/fpm/pool.d/librenms.conf
    
    sed -i 's/user = www-data/user = librenms/' /etc/php/$PHP_VER/fpm/pool.d/librenms.conf
    sed -i 's/group = www-data/group = librenms/' /etc/php/$PHP_VER/fpm/pool.d/librenms.conf
    sed -i 's/\[www\]/\[librenms\]/' /etc/php/$PHP_VER/fpm/pool.d/librenms.conf
    sed -i "s|listen = /run/php/php$PHP_VER-fpm.sock|listen = /run/php-fpm-librenms.sock|" /etc/php/$PHP_VER/fpm/pool.d/librenms.conf
    
    log_success "PHP-FPM pool configurado"
}

configure_nginx() {
    log_info "Configurando Nginx..."
    
    cat > /etc/nginx/conf.d/librenms.conf <<EOF
server {
 listen      80;
 server_name $WEB_HOSTNAME;
 root        /opt/librenms/html;
 index       index.php;

 charset utf-8;
 gzip on;
 gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;
 
 location / {
  try_files \$uri \$uri/ /index.php?\$query_string;
 }
 
 location ~ [^/]\.php(/|$) {
  fastcgi_pass unix:/run/php-fpm-librenms.sock;
  fastcgi_split_path_info ^(.+\.php)(/.+)$;
  include fastcgi.conf;
 }
 
 location ~ /\.(?!well-known).* {
  deny all;
 }
}
EOF
    
    # Eliminar configuración por defecto
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
    
    systemctl restart nginx
    systemctl restart php$PHP_VER-fpm
    
    log_success "Nginx configurado y reiniciado"
}

configure_lnms_command() {
    log_info "Configurando comando lnms..."
    
    ln -sf /opt/librenms/lnms /usr/bin/lnms
    cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/
    
    log_success "Comando lnms configurado"
}

configure_snmp() {
    log_info "Configurando SNMP..."
    
    cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
    sed -i "s/RANDOMSTRINGGOESHERE/$SNMP_COMMUNITY/" /etc/snmp/snmpd.conf
    
    curl -s -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
    chmod +x /usr/bin/distro
    
    systemctl enable snmpd
    systemctl restart snmpd
    
    log_success "SNMP configurado con comunidad segura"
}

configure_cron_and_scheduler() {
    log_info "Configurando tareas programadas..."
    
    cp /opt/librenms/dist/librenms.cron /etc/cron.d/librenms
    cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
    systemctl enable librenms-scheduler.timer
    systemctl start librenms-scheduler.timer
    
    cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms
    
    log_success "Tareas programadas configuradas"
}

configure_firewall() {
    log_info "Configurando firewall UFW..."
    
    ufw allow 'Nginx Full'
    ufw allow SSH
    ufw --force enable
    
    log_success "Firewall configurado (HTTP/HTTPS y SSH permitidos)"
}

configure_env_file() {
    log_info "Configurando archivo .env..."
    
    local escaped_pass=$(escape_password_sed "$LIBRENMS_DB_PASSWORD")
    
    sed -i "s/#DB_HOST=.*/DB_HOST=localhost/" /opt/librenms/.env
    sed -i "s/#DB_DATABASE=.*/DB_DATABASE=$LIBRENMS_DB_NAME/" /opt/librenms/.env
    sed -i "s/#DB_USERNAME=.*/DB_USERNAME=$LIBRENMS_DB_USER/" /opt/librenms/.env
    sed -i "s/#DB_PASSWORD=.*/DB_PASSWORD=$escaped_pass/" /opt/librenms/.env
    
    # Asegurar permisos correctos
    chown librenms:librenms /opt/librenms/.env
    chmod 640 /opt/librenms/.env
    
    log_success "Archivo .env configurado"
}

create_log_file() {
    log_info "Creando archivo de log con permisos correctos..."
    
    touch /opt/librenms/logs/librenms.log
    chown librenms:librenms /opt/librenms/logs/librenms.log
    
    log_success "Archivo de log creado"
}

configure_syslog() {
    if [[ "$SYSLOG_ENABLED" == "true" ]]; then
        log_info "Configurando syslog-ng..."
        
        apt-get install -y -qq syslog-ng-core
        
        cat > /etc/syslog-ng/conf.d/librenms.conf <<'EOF'
source s_net {
        tcp(port(514) flags(syslog-protocol));
        udp(port(514) flags(syslog-protocol));
};

destination d_librenms {
        program("/opt/librenms/syslog.php" template ("$HOST||$FACILITY||$PRIORITY||$LEVEL||$TAG||$R_YEAR-$R_MONTH-$R_DAY $R_HOUR:$R_MIN:$R_SEC||$MSG||$PROGRAM\n") template-escape(yes));
};

log {
        source(s_net);
        source(s_src);
        destination(d_librenms);
};
EOF
        
        chown librenms:librenms /opt/librenms/syslog.php
        chmod +x /opt/librenms/syslog.php
        
        systemctl restart syslog-ng
        
        # Permitir puertos de syslog en firewall
        ufw allow 514/tcp
        ufw allow 514/udp
        
        log_success "Syslog-ng configurado"
    fi
}

# ============================================================================
# FUNCIÓN PRINCIPAL
# ============================================================================

main() {
    echo
    echo "============================================================================"
    echo "  LibreNMS Installation Script - Enterprise Edition"
    echo "  Fecha: $(date)"
    echo "  Log file: $LOG_FILE"
    echo "============================================================================"
    echo
    
    # Validaciones iniciales
    check_root
    check_os
    check_internet
    check_disk_space
    validate_inputs
    
    # Detección dinámica
    detect_php_version
    detect_timezone
    
    # Backup
    create_backup
    
    # Instalación
    install_packages
    create_librenms_user
    clone_repository
    set_permissions
    install_composer
    configure_php_timezone
    configure_mariadb
    create_database
    configure_php_fpm
    configure_nginx
    configure_lnms_command
    configure_snmp
    configure_cron_and_scheduler
    configure_firewall
    configure_env_file
    create_log_file
    configure_syslog
    
    # Finalización
    echo
    echo "============================================================================"
    echo -e "${GREEN}  ¡Instalación completada exitosamente!${NC}"
    echo "============================================================================"
    echo
    echo "Próximos pasos:"
    echo "1. Abre tu navegador en: http://$WEB_HOSTNAME"
    echo "2. Completa el asistente de instalación web"
    echo "3. Después de la instalación web, ejecuta:"
    echo "   sudo -u librenms lnms config:set enable_syslog true"
    echo "4. Valida la instalación:"
    echo "   sudo -u librenms /opt/librenms/validate.php"
    echo
    echo "Información importante:"
    echo "- Log de instalación: $LOG_FILE"
    echo "- Backup de configuraciones: $BACKUP_DIR"
    echo "- Usuario de base de datos: $LIBRENMS_DB_USER"
    echo "- Nombre de base de datos: $LIBRENMS_DB_NAME"
    echo "- SNMP Community: $SNMP_COMMUNITY"
    echo
    echo "============================================================================"
    echo
}

# Ejecutar función principal
main "$@"

exit 0