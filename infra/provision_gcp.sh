#!/usr/bin/env bash
# Provisiona o sistema inteiro do zero numa conta GCP: APIs, rede privada,
# Cloud SQL, firewall e as quatro VMs já configuradas.
#
#   bash infra/provision_gcp.sh
#
# Antes de rodar, só duas coisas precisam estar prontas na mão:
#   1. gcloud instalado e autenticado   (gcloud auth login)
#   2. uma conta de faturamento ativa   (console -> Faturamento)
#
# O script é idempotente: rodar de novo reaproveita o que já existe.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="${PROJECT:-}"
BILLING_ACCOUNT="${BILLING_ACCOUNT:-}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-a}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-small}"
SQL_INSTANCE="${SQL_INSTANCE:-banco-aula-sd}"
SQL_TIER="${SQL_TIER:-db-f1-micro}"
REPO_URL="${REPO_URL:-https://github.com/murilorrs/sd-gastos-grpc.git}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passo() { echo; echo "=====> $*"; }
ja()    { echo "       já existe: $*"; }

ip_privado() {
  gcloud sql instances describe "$SQL_INSTANCE" --format=json 2>/dev/null \
    | python3 -c 'import sys,json
d = json.load(sys.stdin)
print(next((i["ipAddress"] for i in d.get("ipAddresses", [])
            if i.get("type") == "PRIVATE"), ""))' 2>/dev/null
}

# ---------------------------------------------------------------- projeto
if [ -z "$PROJECT" ]; then
  PROJECT=$(gcloud config get-value project 2>/dev/null)
  [ -z "$PROJECT" ] || [ "$PROJECT" = "(unset)" ] && {
    echo "Defina o projeto:  PROJECT=meu-projeto bash infra/provision_gcp.sh"; exit 1; }
fi
gcloud config set project "$PROJECT" --quiet >/dev/null
echo "projeto: $PROJECT    região: $REGION    zona: $ZONE"

passo "faturamento"
if [ "$(gcloud billing projects describe "$PROJECT" --format='value(billingEnabled)' 2>/dev/null)" = "True" ]; then
  ja "faturamento ativo"
else
  if [ -z "$BILLING_ACCOUNT" ]; then
    BILLING_ACCOUNT=$(gcloud billing accounts list --filter="open=true" \
      --format="value(name)" --limit=1 2>/dev/null | sed 's#billingAccounts/##')
  fi
  [ -z "$BILLING_ACCOUNT" ] && {
    echo "Nenhuma conta de faturamento aberta. Crie uma no console e rode de novo."
    echo "Ou passe a sua:  BILLING_ACCOUNT=XXXXXX-XXXXXX-XXXXXX bash infra/provision_gcp.sh"
    exit 1; }
  gcloud billing projects link "$PROJECT" --billing-account="$BILLING_ACCOUNT"
fi

passo "APIs"
gcloud services enable compute.googleapis.com sqladmin.googleapis.com \
  servicenetworking.googleapis.com --quiet

# -------------------------------------------------- rede privada do banco
passo "rede privada para o Cloud SQL"
if gcloud compute addresses describe google-managed-services-default --global --quiet >/dev/null 2>&1; then
  ja "intervalo alocado"
else
  gcloud compute addresses create google-managed-services-default \
    --global --purpose=VPC_PEERING --prefix-length=16 --network=default
fi
if gcloud services vpc-peerings list --network=default \
     --format="value(peering)" 2>/dev/null | grep -q servicenetworking; then
  ja "peering criado"
else
  echo "       criando o peering (alguns minutos)"
  gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com \
    --ranges=google-managed-services-default --network=default --quiet
fi

# -------------------------------------------------------------- Cloud SQL
passo "Cloud SQL"
DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)}"
if gcloud sql instances describe "$SQL_INSTANCE" --quiet >/dev/null 2>&1; then
  ja "instância $SQL_INSTANCE"
  ESTADO=$(gcloud sql instances describe "$SQL_INSTANCE" --format="value(state)")
  if [ "$ESTADO" != "RUNNABLE" ]; then
    echo "       ligando (estava $ESTADO)"
    gcloud sql instances patch "$SQL_INSTANCE" --activation-policy=ALWAYS --quiet
  fi
  if [ -z "$(ip_privado)" ]; then
    echo "       adicionando IP privado (alguns minutos)"
    gcloud sql instances patch "$SQL_INSTANCE" --network=default --quiet
  fi
else
  echo "       criando (10 a 15 minutos; é o passo mais demorado)"
  gcloud sql instances create "$SQL_INSTANCE" \
    --database-version=POSTGRES_15 --tier="$SQL_TIER" --region="$REGION" \
    --network=default --no-assign-ip --storage-size=10 --storage-type=HDD \
    --root-password="$DB_PASSWORD" --quiet
fi

PGHOST=$(ip_privado)
[ -z "$PGHOST" ] && { echo "!! a instância ainda não tem IP privado"; exit 1; }
echo "       IP privado: $PGHOST"

gcloud sql databases describe expenses --instance="$SQL_INSTANCE" --quiet >/dev/null 2>&1 \
  && ja "banco expenses" \
  || gcloud sql databases create expenses --instance="$SQL_INSTANCE" --quiet

if gcloud sql users list --instance="$SQL_INSTANCE" --format="value(name)" | grep -qx expenses_app; then
  ja "usuário expenses_app (senha redefinida)"
  gcloud sql users set-password expenses_app --instance="$SQL_INSTANCE" \
    --password="$DB_PASSWORD" --quiet
else
  gcloud sql users create expenses_app --instance="$SQL_INSTANCE" \
    --password="$DB_PASSWORD" --quiet
fi

# --------------------------------------------------------------- firewall
passo "firewall"
regra() {
  local nome=$1; shift
  if gcloud compute firewall-rules describe "$nome" --quiet >/dev/null 2>&1; then
    ja "$nome"
  else
    gcloud compute firewall-rules create "$nome" --network=default --quiet "$@"
  fi
}
regra allow-web-external --action=allow --direction=ingress \
  --rules=tcp:80 --source-ranges=0.0.0.0/0 --target-tags=grpc-client
regra allow-gateway-internal --action=allow --direction=ingress \
  --rules=tcp:8000 --source-ranges=10.128.0.0/9 --target-tags=grpc-server
regra allow-grpc-internal --action=allow --direction=ingress --priority=800 \
  --rules=tcp:50051,tcp:50052 --source-tags=grpc-server,grpc-service \
  --target-tags=grpc-service
regra deny-grpc-external --action=deny --direction=ingress --priority=900 \
  --rules=tcp:50051,tcp:50052 --source-ranges=0.0.0.0/0 --target-tags=grpc-service

# -------------------------------------------------------------------- VMs
JWT_SECRET="${JWT_SECRET:-$(openssl rand -base64 48 | tr -d '\n')}"
GATEWAY_USER="${GATEWAY_USER:-demo}"
GATEWAY_PASSWORD="${GATEWAY_PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)}"

# Preenche o bloco de CONFIGURAÇÃO do script de inicialização e devolve o
# caminho do arquivo pronto para ir como metadata da VM.
# "0,/^X=/" limita a troca à PRIMEIRA ocorrência — a do bloco de
# CONFIGURAÇÃO. Sem isso o sed também reescreveria as linhas do heredoc que
# monta o server.env, onde X=$X precisa continuar sendo a variável.
preparado() {
  local origem=$1 destino="$TMP/$(basename "$1")"; shift
  cp "$origem" "$destino"
  sed -i "0,/^REPO_URL=/s#^REPO_URL=.*#REPO_URL=\"$REPO_URL\"#" "$destino"
  while [ $# -gt 0 ]; do
    sed -i "0,/^$1=/s#^$1=.*#$1=\"$2\"#" "$destino"
    shift 2
  done
  echo "$destino"
}

cria_vm() {
  local nome=$1 tag=$2 script=$3 externo=$4
  if gcloud compute instances describe "$nome" --zone="$ZONE" --quiet >/dev/null 2>&1; then
    ja "VM $nome"
    return
  fi
  local args=(--zone="$ZONE" --machine-type="$MACHINE_TYPE"
              --image-family=debian-12 --image-project=debian-cloud
              --tags="$tag" --metadata-from-file=startup-script="$script")
  [ "$externo" = "nao" ] && args+=(--no-address)
  gcloud compute instances create "$nome" "${args[@]}" --quiet >/dev/null
  echo "       criada: $nome"
}

ip_interno() {
  gcloud compute instances describe "$1" --zone="$ZONE" \
    --format="value(networkInterfaces[0].networkIP)"
}

passo "vm-cards"
cria_vm vm-cards grpc-service "$(preparado infra/startup-cards.sh \
  PGHOST "$PGHOST" PGPASSWORD "$DB_PASSWORD")" nao
CARDS_IP=$(ip_interno vm-cards)

passo "vm-expenses"
cria_vm vm-expenses grpc-service "$(preparado infra/startup-expenses.sh \
  PGHOST "$PGHOST" PGPASSWORD "$DB_PASSWORD" CARDS_ADDR "$CARDS_IP:50052")" nao
EXPENSES_IP=$(ip_interno vm-expenses)

passo "vm-server"
cria_vm vm-server grpc-server "$(preparado infra/startup-server.sh \
  CARDS_ADDR "$CARDS_IP:50052" EXPENSES_ADDR "$EXPENSES_IP:50051" \
  JWT_SECRET "$JWT_SECRET" GATEWAY_USER "$GATEWAY_USER" \
  GATEWAY_PASSWORD "$GATEWAY_PASSWORD" ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY")" nao
SERVER_IP=$(ip_interno vm-server)

passo "vm-client"
cria_vm vm-client grpc-client "$(preparado infra/startup-client.sh \
  GATEWAY_HOST "$SERVER_IP")" sim
EXTERNO=$(gcloud compute instances describe vm-client --zone="$ZONE" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

# ------------------------------------------------------------- resultado
cat > credenciais.txt <<FIM
projeto           $PROJECT
zona              $ZONE

interface web     http://$EXTERNO
usuário           $GATEWAY_USER
senha             $GATEWAY_PASSWORD

banco             $PGHOST:5432  (expenses / expenses_app)
senha do banco    $DB_PASSWORD
jwt secret        $JWT_SECRET

vm-cards          $CARDS_IP:50052
vm-expenses       $EXPENSES_IP:50051
vm-server         $SERVER_IP:8000
FIM
chmod 600 credenciais.txt

cat <<FIM

=====> pronto

  Interface web:  http://$EXTERNO
  Login:          $GATEWAY_USER / $GATEWAY_PASSWORD

  Tudo isso também ficou em credenciais.txt (fora do git).

As VMs ainda estão instalando — os scripts de inicialização levam de 3 a 8
minutos, e a vm-client é a mais lenta porque compila o frontend. Acompanhe:

  bash infra/verifica.sh

FIM
