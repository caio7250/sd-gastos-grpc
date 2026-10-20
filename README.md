# Expense tracking over gRPC

> **Integrantes:** Murilo Rodrigues, (preencher), (preencher)

Trabalhos 1 e 2 de Sistemas Distribuídos — um sistema de controle de gastos com
**interface web em React**, **API Gateway (FastAPI)**, **dois microsserviços
gRPC** e **PostgreSQL** (Cloud SQL), rodando em duas VMs no **Google Cloud
Platform**.

O usuário registra e consulta gastos pela interface web, que fala **só com o
Gateway**, por HTTP/JSON e com um token JWT. O Gateway autentica, valida o
payload e traduz cada chamada para **gRPC/protobuf**, despachando para o
microsserviço dono do dado — **Cartões** ou **Gastos** — que persiste no banco.

A interface também aceita a frase solta ("gastei 89 reais num teclado no
crédito do Nubank"): o Gateway manda o texto para a API da Anthropic, recebe um
comando estruturado e o despacha pelos mesmos RPCs. Nenhum microsserviço sabe
que existe um modelo de linguagem — chega o mesmo protobuf que chegaria de um
formulário.

> Código, identificadores e mensagens do backend em inglês; comentários em
> português. A interface é em português, e traduz as mensagens do backend na
> hora de exibir (`web/src/shared/messages.ts`) — uma mensagem de protocolo não
> muda porque a tela mudou de idioma.

| Documento | Para quê |
|---|---|
| [`docs/GCP-CONSOLE.md`](docs/GCP-CONSOLE.md) | subir tudo pelo Google Cloud Console, clique a clique |
| [`docs/APRESENTACAO.md`](docs/APRESENTACAO.md) | roteiro cronometrado dos 10 minutos de demonstração |

## Arquitetura

```
   navegador          vm-client              vm-server
  ┌──────────┐    ┌──────────────┐     ┌──────────────────────┐
  │  React   │ :80│ nginx        │     │ API Gateway (FastAPI)│
  │  (SPA)   ├───►│  / → dist    │JSON │ 0.0.0.0:8000         │
  └──────────┘    │  /api ───────┼────►│  JWT (401)·valida(400)│
                  └──────────────┘+JWT │  JSON ──► protobuf    │
                                       │  texto ─► Claude      │
                                       └────┬─────────────┬────┘
                                       gRPC │             │ gRPC
                                            ▼             ▼
                                      vm-cards        vm-expenses
                                    Cartões :50052 ◄── Gastos :50051
                                            │ ValidateCard │
                                            └──────┬───────┘
                                                   ▼
                                       Cloud SQL (PostgreSQL)
                                       10.115.48.3:5432 · IP privado

   firewall   tcp:80    ← 0.0.0.0/0          → tag grpc-client
              tcp:8000  ← 10.128.0.0/9       → tag grpc-server
         800  tcp:5005x ← tags grpc-server,  → tag grpc-service   (allow)
                          grpc-service
         900  tcp:5005x ← 0.0.0.0/0          → tag grpc-service   (deny)
```

Cada serviço roda na sua própria VM. Cinco saltos, cada um com um protocolo e
um motivo:

1. **Navegador → nginx: HTTP.** O nginx da `vm-client` serve os arquivos
   estáticos do build e repassa `/api/*` ao Gateway. É por isso que o
   navegador vê **uma origem só** e o sistema não depende de CORS.
2. **nginx → Gateway: HTTP/JSON com JWT.** É a única porta de entrada da API.
3. **Gateway → microsserviços: gRPC/protobuf.** O Gateway desserializa o
   JSON, valida, e serializa em protobuf para o serviço dono do dado.
4. **Gastos → Cartões: gRPC.** Antes de gravar ou alterar um gasto, o serviço
   de Gastos pergunta ao de Cartões se o cartão existe. É a comunicação entre
   microsserviços do sistema, e atravessa a rede entre duas VMs.
5. **Microsserviços → Cloud SQL: PostgreSQL**, pela rede privada. Cada serviço
   só toca a sua tabela — e só eles têm as credenciais do banco; o Gateway
   não as recebe.

**Uma porta aberta para a internet no sistema inteiro:** a 80 da `vm-client`.

**O que protege os microsserviços.** Eles escutam em `0.0.0.0`, porque quem os
chama vem de outra máquina. O muro é o par de regras de firewall 800/900: o
`allow` deixa passar quem tem a tag `grpc-server` ou `grpc-service`, e o
`deny`, logo abaixo, recusa todo o resto. A ordem é o que faz a coisa
funcionar — a regra `default-allow-internal`, que o GCP cria sozinho e libera
todas as portas entre VMs da VPC, tem prioridade 65534 e nunca é alcançada
para essas portas. Sem o `deny`, a `vm-client` falaria direto com os
microsserviços, e o requisito de o frontend falar só com o Gateway cairia.

**Rastreio.** O Gateway gera um identificador curto por requisição HTTP e o
envia na metadata de toda chamada gRPC; o serviço de Gastos o repassa ao de
Cartões. As três VMs logam a mesma operação com o mesmo id, e ele volta ao
navegador no cabeçalho `X-Request-Id`:

```
vm-server    [45b51b84] RegisterExpense  JSON -> protobuf 40 bytes
vm-expenses  [45b51b84] RegisterExpense  from 10.128.0.2  teclado 389.90 Nubank/credit
vm-cards     [45b51b84] ValidateCard     from 10.128.0.5  Nubank / credit
```

**Prazo em toda chamada.** Todas as chamadas gRPC do Gateway passam pela mesma
função `call()`, que fixa um deadline de 10 segundos; a chamada entre
microsserviços usa 5. Sem prazo, um serviço lento prenderia o Gateway junto.

**A LLM vive no Gateway.** Ela está na borda, e não no cliente, porque a chave
da API não pode ir para o navegador. Os microsserviços continuam recebendo só
protobuf: nenhum deles sabe que existe um modelo de linguagem. O cliente de
terminal (`client/client.py`) segue funcionando com o seu próprio
interpretador — os dois lados compartilham o mesmo módulo, em `language/`.

### Banco de dados

Em produção os microsserviços usam um **Cloud SQL para PostgreSQL** com **IP
privado apenas** — o banco não tem endereço público; só máquinas dentro da VPC
`default` o alcançam, pelo peering de *Private Services Access*.

Cada microsserviço é dono de uma tabela: Cartões tem `cards`, Gastos tem
`expenses`. Não há chave estrangeira entre elas — ela acoplaria os dois
serviços por baixo do contrato. O serviço de Gastos só sabe se um cartão existe
perguntando ao de Cartões via gRPC, e grava com a grafia que ele devolve.

O `database.py` escolhe o backend pelo ambiente: com `PGHOST` definido, conecta
no PostgreSQL usando as variáveis padrão do libpq (`PGHOST`, `PGPORT`,
`PGDATABASE`, `PGUSER`, `PGPASSWORD`); sem ele, usa arquivos SQLite em `data/`.
O SQLite fica para desenvolvimento local e para os testes — o Mac está fora da
VPC e não alcança o IP privado. As consultas são as mesmas nos dois.

Os segredos ficam separados por VM, e cada uma recebe só o que usa. A senha do
banco vai para a `vm-cards` e a `vm-expenses`, que são as únicas que falam com
o PostgreSQL. O segredo do JWT, o login e a chave da LLM vão para a
`vm-server`, que é quem emite token e interpreta texto. **O Gateway não recebe
a senha do banco, e os microsserviços não recebem o segredo do JWT** — nenhum
dos dois teria o que fazer com ela. Todos ficam em
`/opt/sd-gastos-grpc/server.env`, legível só por root.

## Frontend

React + TypeScript, compilado pelo Vite e servido como arquivos estáticos pelo
nginx. **Ele só conhece o Gateway**: todas as chamadas saem de
`web/src/shared/services/api.ts` para o caminho relativo `/api`, que o nginx
(em produção) ou o proxy do Vite (em desenvolvimento) repassa. Não há endereço
de microsserviço em lugar nenhum do código do frontend, nem adiantaria haver —
o firewall só deixa o Gateway alcançá-los.

| Tela | O que faz | RPCs por trás |
|---|---|---|
| **Login** | troca usuário e senha por um JWT | — (`POST /auth/token`) |
| **Painel** | totais do período em cartões e gráficos | `SummaryByGroup` ×3, `SearchExpenses`, `ListCards` |
| **Gastos** | buscar, registrar, **alterar** e **remover** | `SearchExpenses`, `RegisterExpense`, `UpdateExpense`, `DeleteExpense` |
| **Cartões** | cadastrar, listar e testar um nome | `RegisterCard`, `ListCards`, `ValidateCard` |
| **Assistente** | a frase em português vira comando e é executada | o RPC que o comando pedir |
| **Laboratório** | dispara os casos de 401, 400 e 201 e mostra a troca HTTP inteira | vários |

O **Laboratório** existe por causa do critério de avaliação: são doze cenários
— três de 401, seis de 400 e três do caminho feliz —, cada um com o status que
se espera dele ao lado do que o Gateway de fato devolveu. Nada ali é simulado — são requisições HTTP de verdade, e o painel da
direita mostra o cabeçalho de autorização, o corpo enviado e o corpo recebido.
É também um log vivo: qualquer navegação pelo sistema aparece nele.

O token fica no `sessionStorage` (some quando a aba fecha) e não é enviado por
cookie, então não há CSRF a tratar. Quando ele vence — uma hora —, a próxima
chamada volta 401, a camada de API derruba a sessão e a tela de login avisa.

As listas fechadas de categorias, métodos e períodos **não são repetidas no
frontend**: vêm de `GET /meta`, que as publica a partir dos mesmos tipos que o
Gateway usa para validar. Uma cópia local sairia de sincronia com a validação
real na primeira mudança.

Os componentes de interface (`web/src/shared/ui/`) vieram de um projeto
existente e foram reajustados aqui: paleta nova e uma escala de raio e de
sombra quase reta — 2px nos controles, 3px nas superfícies, sombra só no que
de fato flutua (modal e toast). Cantos redondos escondem a grade; com a borda
quase reta, o alinhamento entre tabela, cartão e formulário fica visível. Tudo
isso mora em `web/src/shared/ui/tokens.css`, então a decisão é de um arquivo
só.

## API Gateway

| Método e rota | Microsserviço | Sucesso |
|---|---|---|
| `POST /auth/token` | — (emite o JWT) | 200 |
| `GET /health` | — | 200 |
| `GET /meta` | — (listas fechadas para a interface) | 200 |
| `GET /cards` | Cartões · `ListCards` | 200 |
| `POST /cards` | Cartões · `RegisterCard` | **201**, ou 200 se já existia |
| `GET /cards/validate` | Cartões · `ValidateCard` | 200 |
| `POST /expenses` | Gastos · `RegisterExpense` (→ Cartões · `ValidateCard`) | **201** |
| `GET /expenses` | Gastos · `SearchExpenses` (stream) | 200 |
| `GET /expenses/summary` | Gastos · `SummaryByGroup` | 200 |
| `PUT /expenses/{id}` | Gastos · `UpdateExpense` (→ Cartões · `ValidateCard`) | 200 |
| `DELETE /expenses/{id}` | Gastos · `DeleteExpense` | 200 |
| `POST /nlu/interpret` | Claude, e depois o RPC que o comando pedir | 200 |

Documentação interativa, gerada pelo FastAPI, em `http://<gateway>:8000/docs`.

**Autenticação.** Toda rota exceto `/auth/token` e `/health` exige
`Authorization: Bearer <token>`. Sem token, com token inválido ou vencido
(uma hora), a resposta é **401** — antes de qualquer chamada gRPC.

**Validação.** Os corpos e parâmetros são declarados como modelos Pydantic:
campos obrigatórios, `amount > 0`, `method` só `CREDIT` ou `DEBIT`, categoria
de uma lista fechada, datas no formato `AAAA-MM-DD`. Qualquer violação, e JSON
malformado, resulta em **400** (o FastAPI usaria 422 por padrão; o enunciado
pede 400). Um cartão inexistente também é 400 — quem diz isso é o serviço de
Cartões, consultado pelo de Gastos.

```bash
TOKEN=$(curl -s localhost:8000/auth/token -H 'Content-Type: application/json' \
  -d '{"username":"demo","password":"..."}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

curl -i localhost:8000/expenses                                   # 401
curl -i localhost:8000/expenses -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"product":"x","amount":0}' -X POST   # 400
```

## Contrato

`proto/expenses.proto` define dois serviços, que compartilham as mensagens:

| Serviço | RPC | Tipo | Para quê |
|---|---|---|---|
| `CardService` | `RegisterCard` | unário | cadastra a dupla (nome, método) |
| | `ListCards` | unário | alimenta o prompt do modelo com cartões reais |
| | `ValidateCard` | unário | confere um cartão e devolve a grafia cadastrada |
| `ExpenseService` | `RegisterExpense` | unário | grava o gasto, depois de consultar o `CardService` |
| | `SearchExpenses` | **streaming** | devolve os gastos um a um |
| | `SummaryByGroup` | unário | totais por `category`, `card` ou `method` |
| | `UpdateExpense` | unário | regrava o gasto, revalidando o cartão |
| | `DeleteExpense` | unário | remove o gasto |

Um cartão é a dupla **(name, method)**: "Nubank credit" e "Nubank debit" são
registros distintos, o que permite responder "gastos do Nubank no crédito" sem
ambiguidade.

## Como o modelo é impedido de alucinar

Três camadas independentes, porque uma LLM erra e o sistema não pode gravar
lixo por causa disso:

1. **Restrição na entrada** — antes de montar o prompt, o Gateway chama
   `ListCards` e injeta a lista real de cartões, junto com uma lista fechada de
   categorias. O modelo escolhe dentro do que existe em vez de inventar.
2. **Verificação antes de agir** — se o comando cita um cartão, o Gateway
   chama `ValidateCard` **antes** de gravar ou buscar. Se o cartão não existir,
   devolve as opções em vez de executar (`difflib` no serviço de Cartões
   resolve "Nubanck" → "Nubank").
3. **Garantia no backend** — mesmo que as duas camadas acima falhem, o Gateway
   recusa categoria fora da lista, e o serviço de Gastos recusa gravar se o de
   Cartões não confirmar o cartão. Se o serviço de Cartões estiver fora do ar,
   Gastos recusa em vez de gravar às cegas.

As três valem para os dois interpretadores — o da API da Anthropic e o de
regras locais —, porque nenhuma delas mora no interpretador.

### Recuperação: recusar não é o fim

Quando a validação falha, o comando não é descartado — as saídas possíveis
voltam junto com ele, e o usuário completa a operação escolhendo uma.

Na web, `POST /nlu/interpret` responde 200 com `status: "needs_card"` (ou
`"needs_method"`), a mensagem do serviço de Cartões, as `suggestions` e um
`pending` com o gasto já montado — inclusive **a data já resolvida**, para a
interface não precisar interpretar "ontem" por conta própria. A tela vira
botões; escolher um cadastra o cartão (`POST /cards`) e lança o gasto
(`POST /expenses`), sem redigitar a frase.

No terminal, o mesmo material vira um menu numerado:

```
> gastei 55 reais no crédito do Itaú
  x card Itau is registered, but not for credit (only: debit)
  how do you want to proceed?
    1) use Itau (debit)
    2) register Itau for credit and record it there
    0) cancel
  choice> 2
  + Itau (credit) registered
  + #3  expense  55.00  Itau/credit
```

| Situação | O que é oferecido |
|---|---|
| Cartão não existe, num registro | usar um cadastrado, ou cadastrar o novo e lançar nele |
| Cartão não existe, numa consulta | apenas os cartões cadastrados (não faz sentido criar) |
| Método não informado, num registro | crédito ou débito — mas só se o cartão tiver os dois |

Cancelar não grava nada. Sem terminal interativo (entrada redirecionada), o
menu cancela em vez de executar o comando pela metade.

### Datas

O modelo devolve um **rótulo** (`this_month`, `yesterday`), e quem calcula o
intervalo é o `datetime` em `language/period.py`. Modelos erram aritmética de
data, e aqui o erro seria silencioso.

Duas defesas concretas nasceram de erros observados em teste, não de suposição:

- O modelo devolveu `last_month` como data de uma transação, um rótulo de
  período onde se esperava um único dia. Cair para "hoje" gravaria a data
  errada em silêncio, então `transaction_date` resolve o período para o seu
  último dia, limitado a hoje.
- O modelo colocou o tempo no campo `period` em vez de `date_label` num
  registro. Quem despacha aceita os dois nomes: depender do modelo acertar o
  nome do campo é frágil demais para um dado que ninguém confere.

## Configuração da LLM

```
ANTHROPIC_API_KEY=...     # console.anthropic.com -> API keys
ANTHROPIC_MODEL=claude-haiku-4-5
ANTHROPIC_TIMEOUT=30
```

A chave sai em `console.anthropic.com` e exige créditos em Billing (pré-pago,
mínimo US$ 5). Liste os modelos da conta com `python language/nlu.py --models`.

Este projeto usou o Gemini primeiro e migrou por dois motivos medidos: o free
tier dava **20 requisições por dia** por modelo, e a latência ficava entre **10
e 25 segundos** com o serviço carregado. Com o Haiku 4.5 a interpretação leva
**1,8 a 3,7 segundos**, e custa cerca de **US$ 0,0012 por comando**. A troca
mexeu apenas em `language/nlu.py`.

**A chave é opcional.** Sem ela, o Gateway usa o interpretador por regras de
`language/nlu.py` (`interpret_offline`), que cobre os comandos do roteiro de
demonstração, e a interface avisa qual dos dois respondeu. Nada da
demonstração depende da API estar no ar.

## Rodando localmente

### Com Docker: o sistema inteiro, com PostgreSQL de verdade

É a mesma topologia do GCP, encolhida: um container por VM. `web` faz o papel
do nginx da `vm-client`, `gateway` o da `vm-server`, `cards` e `expenses` o das
VMs de mesmo nome, e `db` o do Cloud SQL. Cada container é um host de rede
distinto, com IP próprio — é o ensaio fiel da separação em VMs, e nenhuma
linha de código muda entre os dois ambientes. Serve para desenvolver e como
plano B na apresentação.

```bash
docker compose up --build
# abra http://localhost:8080  (usuário demo, senha demo-password)
```

Repare no que **não** tem porta publicada: `cards`, `expenses` e `db`. Eles só
existem dentro da rede do compose, que é o papel que o par de regras de
firewall faz no GCP. Para conferir que os dados são reais:

```bash
docker compose exec db psql -U expenses_app -d expenses -c "SELECT * FROM expenses;"
```

### Sem Docker: processo a processo

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r server/requirements.txt -r gateway/requirements.txt -r client/requirements.txt
bash generate_stubs.sh
cp .env.example .env      # preencha JWT_SECRET, GATEWAY_USER, GATEWAY_PASSWORD
```

Em um terminal, o backend inteiro — os dois microsserviços e o Gateway, com
SQLite em `data/`:

```bash
bash run_backend.sh
```

Em outro, a interface web:

```bash
cd web && npm install && npm run dev
# abra http://localhost:5173
```

O servidor do Vite repassa `/api` para `localhost:8000`, que é o mesmo papel do
nginx em produção — por isso o frontend chama o caminho relativo nos dois
ambientes, e não existe CORS a configurar.

Quem preferir o terminal ao navegador:

```bash
python client/client.py --verbose
```

Sem chave da Anthropic, use `--offline`: o mesmo interpretador por regras que o
Gateway usa quando a chave não está definida.

### Comandos de exemplo

```
cadastra o Nubank no crédito e no débito, e o Itaú no débito
gastei 89 reais num teclado mecânico no crédito do Nubank
almoço de 42 reais no débito do Itaú ontem
me mostra tudo que eu gastei no Nubank no crédito esse mês
quanto gastei em tecnologia?
resumo por método
```

Dentro do REPL:

| Comando | O que faz |
|---|---|
| `:verbose` | mostra o comando estruturado que a LLM devolveu e os tempos de cada etapa |
| `:bytes` | mostra a requisição HTTP e o JSON enviado ao Gateway |
| `:cards` | lista os cartões cadastrados |
| `:clear` | limpa a tela |
| `:help` | exemplos de comandos |
| `:quit` | sai |

`:verbose` e `:bytes` também têm as flags `--verbose` e `--bytes`. O outro lado
da tradução — o tamanho do protobuf que o Gateway monta a partir do JSON —
aparece no log do Gateway, em linhas como
`RegisterExpense  JSON -> protobuf 114 bytes`.

## Verificação

```bash
python language/period.py        # aritmética de datas, incluindo virada de ano
python server/test_services.py   # os dois microsserviços por canais gRPC reais
python gateway/test_gateway.py   # 401, 400, 201, o ciclo do gasto e a rota de NLU
cd web && npx tsc --noEmit       # tipos do frontend contra o contrato do Gateway
```

Os testes sobem os serviços em portas efêmeras e conversam com eles por canais
de verdade — exercitam serialização e transporte, não só as funções Python. O
de serviços inclui o caso em que Cartões cai e Gastos precisa recusar, e o
ciclo completo do gasto (criar, alterar, remover). O do Gateway cobre 401 sem
token, 400 para cada forma de payload inválido, 201 na criação, e a rota de
linguagem natural pelo caminho offline — que é o que permite rodá-la sem chave
de API e sem rede.

A verificação que vale mais na apresentação, porém, é a tela do
**Laboratório**: ela roda os doze cenários contra o sistema que está no ar,
não contra portas efêmeras de teste.

## Deploy no GCP

Duas formas, com o mesmo resultado.

**Pelo console**, clique a clique, incluindo a criação do Cloud SQL e das
regras de firewall: [`docs/GCP-CONSOLE.md`](docs/GCP-CONSOLE.md). Os dois
scripts de inicialização — [`infra/startup-server.sh`](infra/startup-server.sh)
e [`infra/startup-client.sh`](infra/startup-client.sh) — são feitos para colar
no campo "Script de inicialização" da tela de criação da VM: cada um tem um
bloco de CONFIGURAÇÃO no topo e faz o resto sozinho.

**Pela linha de comando**, com o `gcloud` já autenticado:

```bash
cp infra/config.sh.example infra/config.sh   # edite o PROJECT
bash infra/setup_gcp.sh                      # VMs + regras de firewall
bash infra/deploy.sh                         # clona, instala, compila e sobe
```

Cada VM de backend sobe um serviço do systemd, que volta sozinho se a máquina
reiniciar: `cards` na `vm-cards`, `expenses` na `vm-expenses`, `gateway` na
`vm-server`. Na `vm-client` sobe o nginx com o build do frontend.

A ordem importa, porque cada uma precisa do IP interno da anterior:
**Cartões → Gastos → Gateway → frontend**. Para acompanhar, uma janela por VM:

```bash
sudo journalctl -u cards -f        # na vm-cards
sudo journalctl -u expenses -f     # na vm-expenses
sudo journalctl -u gateway -f      # na vm-server
```

O mesmo `[id]` aparece nas três: é a mesma requisição atravessando o sistema.

As quatro regras de firewall criadas pelo `setup_gcp.sh`:

```
      tcp:80     ←  0.0.0.0/0                      →  tag grpc-client
      tcp:8000   ←  10.128.0.0/9                   →  tag grpc-server
 800  tcp:5005x  ←  tags grpc-server, grpc-service →  tag grpc-service  allow
 900  tcp:5005x  ←  0.0.0.0/0                      →  tag grpc-service  deny
```

A interface web é a única coisa exposta à internet. O Gateway só responde de
dentro da VPC; os microsserviços, só ao Gateway e um ao outro; e o banco não
tem endereço público.

## Requisitos do Trabalho 2

| Requisito | Onde é atendido |
|---|---|
| Interface visual funcional | `web/` — React + TypeScript: painel com gráficos, CRUD de gastos, cartões, assistente e laboratório |
| Frontend fala **só** com o Gateway | `web/src/shared/services/api.ts` — toda chamada sai para `/api`, que o nginx repassa ao Gateway. Não há endereço de microsserviço no frontend, e o firewall só deixa o Gateway alcançá-los |
| API Gateway com framework web | `gateway/app.py` — FastAPI, ponto único de entrada |
| Mínimo de 2 microsserviços gRPC | `server/cards_service.py` e `server/expenses_service.py` |
| Comunicação entre microsserviços via gRPC | `ExpenseService._validate_card` chama `CardService.ValidateCard` antes de gravar e antes de alterar |
| Banco de dados real, sem mocks | Cloud SQL PostgreSQL (`server/database.py`); consulta, inserção, **alteração** e remoção passam por ele. Não existe lista em memória em lugar nenhum |
| Validação no Gateway: 400 / 201 | modelos Pydantic + tratador de `RequestValidationError`; `POST` retorna 201. Demonstrável na tela **Laboratório** |
| JWT no Gateway: 401 | dependência `require_token` em todas as rotas de negócio, incluindo `/meta` e `/nlu/interpret` |
| Tradução JSON → gRPC/protobuf | função `call` do Gateway, que registra o tamanho do protobuf de cada chamada |
| Demonstração de sucesso e de falha | tela **Laboratório**: doze cenários com o status esperado ao lado do obtido |

## Requisitos do Trabalho 1

| Requisito | Onde é atendido |
|---|---|
| Contrato `.proto` com estruturas de dados e serviços RPC | `proto/expenses.proto` |
| Comunicação síncrona e eficiente | RPCs unários + 1 server-streaming (`SearchExpenses`) |
| Regras de firewall VPC no GCP | `infra/setup_gcp.sh` |
| Infraestrutura em nuvem (GCP) | 4 VMs, uma por serviço, + Cloud SQL — veja [`docs/GCP-CONSOLE.md`](docs/GCP-CONSOLE.md) |
| Código-fonte no GitHub | este repositório |

O enunciado pede **um** repositório contendo os arquivos `.proto` e o código dos
microsserviços. Microsserviço é sobre processos separados, não sobre
repositórios separados — e o `.proto` ser compartilhado por todos os lados é
justamente o que torna o repositório único a escolha certa: em repositórios
distintos, o contrato dessincroniza.

## Estrutura

```
proto/expenses.proto     contrato: CardService e ExpenseService
generate_stubs.sh        gera os stubs para server/ e gateway/ (fora do git)
run_backend.sh           sobe o backend local: os dois serviços e o Gateway
docker-compose.yml       o sistema inteiro em containers, com PostgreSQL

gateway/                 API Gateway: app.py, test_gateway.py
server/                  microsserviços: cards_service.py, expenses_service.py,
                         common.py, database.py, test_services.py
language/                nlu.py e period.py — a camada de linguagem natural,
                         compartilhada pelo Gateway e pelo cliente de terminal
client/                  cliente de terminal: client.py
web/                     frontend React
  src/config/            marca e tema (cores, fonte, logotipo)
  src/shared/ui/         design system: Button, Input, Table, Modal, Card...
  src/shared/services/   api.ts (fetch + JWT + log) e gateway.ts (o contrato)
  src/features/          uma pasta por tela: auth, dashboard, expenses,
                         cards, assistant, lab

infra/                   setup_gcp.sh, deploy.sh, um startup script por VM
                         (cards, expenses, server, client), nginx.conf,
                         cloud-sql.sql e as units do systemd
docs/                    GCP-CONSOLE.md e APRESENTACAO.md
```

Os stubs gerados não são versionados — `generate_stubs.sh` os recria. Isso
evita o problema clássico de stub dessincronizado do `.proto`.

`language/` fica na raiz, fora de `gateway/` e de `client/`, porque os dois a
usam: o Gateway interpreta o texto que vem da web, o cliente interpreta o que
vem do REPL. Um prompt só, um interpretador só — duplicá-lo seria garantir que
as duas pontas divergissem.
