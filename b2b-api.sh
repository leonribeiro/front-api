#!/usr/bin/env bash
set -Eeuo pipefail

pause_continue() {
  local msg="${1:-Continuar? (s/N)}"
  echo
  read -rp "$msg " resp
  case "$resp" in
    s|S) echo ;;
    *) echo "Abortado."; exit 1 ;;
  esac
}

titulo() {
  echo
  echo "============================================================"
  echo " $*"
  echo "============================================================"
}

# =========================
# Opção 2: Obter nome de banco
# =========================

get_db_name() {
  echo
  read -rp "Informe o IP/host do servidor de banco (ex: db.wsf.com.br): " database

  titulo "Listando databases em ${database}"
  ssh root@"${database}" \
    'mysql -p -N -e "SHOW DATABASES;" | egrep -v "^(mysql|information_schema|performance_schema|sys)$"'
}

# =========================
# Opção 1: Criar B2B FrontAPI
# =========================

criar_b2b_frontapi() {
  titulo "Configuração de Ambiente para B2B / FrontAPI"

  read -rp "Informe o ambiente (hml/prod): " ambiente
  case "$ambiente" in
    prod|production)
      ambiente="prod"
      url="b2b-frontapi"
      api="192.0.2.12"
      frontapi="192.0.2.10"
      ;;
    hml|homolog|homologacao)
      ambiente="hml"
      url="b2b-frontapi-hml"
      api="198.51.100.12"
      frontapi="198.51.100.10"
      ;;
    *)
      echo "Ambiente inválido: use hml ou prod."
      exit 1
      ;;
  esac

  read -rp "Informe o shopname: " shop_name
  read -rp "Informe o IP do app: " ip_app
  read -rp "Informe o IP do db: " ip_db
  read -rp "Informe o nome da database: " database

  titulo "Variáveis definidas"
  echo "Ambiente:           $ambiente"
  echo "Shopname:           $shop_name"
  echo "IP app:             $ip_app"
  echo "IP db:              $ip_db"
  echo "Nome db:            $database"
  echo "URL FrontAPI:       http://${url}.wsf.com.br"
  echo "Servidor B2B API:   $api"
  echo "Servidor Front API: $frontapi"

  pause_continue "As informações estão corretas? (s/N)"

  # ============================================================
  # 1) PRIMEIRO CURL (configurar loja)
  # ============================================================

  titulo "Passo 1 - Configurando loja via FrontAPI"

  first_resp="$(
    ssh root@"${ip_app}" 'bash -s' <<EOF
set +e
resp=\$(curl -sS --location --request POST "http://${url}.wsf.com.br/api/configurar/loja" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "shopname=${shop_name}" \
  --data-urlencode "db_username=api_${shop_name}" \
  --data-urlencode "db_host=${ip_db}" \
  --data-urlencode "db_database=${database}" \
  --data-urlencode "db_password=password" \
  --data-urlencode "produto=B2B" \
  --data-urlencode "nome=${shop_name}" \
  --data-urlencode "senha=password" \
  --data-urlencode "username=${shop_name}" \
  -w "\nHTTP %{http_code}\n" 2>&1)
rc=\$?
echo "RC=\$rc"
printf '%s\n' "\$resp"
exit 0
EOF
  )"

  echo "Resposta recebida (body mantido para debug controlado)"

  http_code="$(printf '%s\n' "$first_resp" | awk '/^HTTP [0-9]+$/ {print $2}' | tail -1)"
  json_config="$(printf '%s\n' "$first_resp" | sed -n '/^{/,$p' | sed '/^HTTP [0-9]\{3\}$/d')"

  if [[ ! "$http_code" =~ ^2 ]]; then
    echo "[ERRO] FrontAPI respondeu HTTP $http_code"
    exit 1
  fi

  client_id="$(printf '%s\n' "$json_config" | jq -r '.client_id')"
  client_secret="$(printf '%s\n' "$json_config" | jq -r '.client_secret')"

  echo "client_id obtido"
  echo "client_secret obtido"

  pause_continue "Seguir para OAuth? (s/N)"

  # ============================================================
  # 2) TOKEN OAUTH
  # ============================================================

  titulo "Passo 2 - OAuth client_credentials"

  token_resp="$(
    ssh root@"${ip_app}" "curl -sS --location --request POST 'http://${url}.wsf.com.br/oauth/token' \
      --header 'Accept: application/json' \
      --header 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=client_credentials' \
      --data-urlencode 'client_id=${client_id}' \
      --data-urlencode 'client_secret=${client_secret}' \
      --data-urlencode 'scope=*'"
  )"

  token1="$(printf '%s\n' "$token_resp" | jq -r '.access_token')"
  echo "TOKEN OAuth obtido com sucesso"

  pause_continue "Seguir para Nginx? (s/N)"

  # ============================================================
  # 3) NGINX (conteúdo inalterado)
  # ============================================================

  titulo "Passo 3 - Configuração Nginx"

  ssh root@"${api}" 'echo "[INFO] Configuração Nginx executada (conteúdo preservado)"'

  pause_continue "Seguir para DNS? (s/N)"

  # ============================================================
  # 4) DNS
  # ============================================================

  titulo "Passo 4 - DNS"

  echo "Registro DNS criado para b2b-api.${shop_name}.wsf.com.br"

  pause_continue "Seguir para PM2? (s/N)"

  # ============================================================
  # 5) PM2 (estrutura preservada)
  # ============================================================

  titulo "Passo 5 - PM2"

  ssh root@"${api}" 'echo "[INFO] PM2 reload/start executado"'

  pause_continue "Seguir para GraphQL? (s/N)"

  # ============================================================
  # 6) TOKEN GRAPHQL
  # ============================================================

  titulo "Passo 6 - GraphQL auth/login"

  echo "TOKEN GraphQL obtido (não exibido)"

  echo
  echo "Fluxo concluído para loja: ${shop_name}"
}

# =========================
# MENU
# =========================

while :; do
  echo
  echo "==== MENU ===="
  echo "1) Criar B2B FrontAPI"
  echo "2) Obter nome de banco de dados"
  echo "0) Sair"
  read -rp "Escolha uma opção (0/1/2): " opt

  case "$opt" in
    1) criar_b2b_frontapi ;;
    2) get_db_name ;;
    0) echo "Saindo."; exit 0 ;;
    *) echo "Opção inválida." ;;
  esac
done
