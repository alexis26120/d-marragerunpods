#!/bin/bash
# =============================================================================
# setup_comfyui_supir.sh
# Setup automatique : SUPIR + Moondream sur RunPod ComfyUI
#
# Usage :
#   bash setup_comfyui_supir.sh
#   bash setup_comfyui_supir.sh --skip-models
#   bash setup_comfyui_supir.sh --civitai-token=TON_TOKEN
#   bash setup_comfyui_supir.sh --hf-token=TON_TOKEN
#
# Les tokens peuvent aussi être passés via variables d'env :
#   export HF_TOKEN=xxx CIVITAI_TOKEN=xxx && bash setup_comfyui_supir.sh
# =============================================================================

# PAS de set -e : on gère les erreurs manuellement pour ne jamais foire
# sur un simple 404 ou token manquant

# ── Couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
skip()  { echo -e "${YELLOW}[↷]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }      # err() ne quitte plus le script
info()  { echo -e "${CYAN}[→]${NC} $1"; }

# Compteurs pour le résumé final
ERRORS=()
SKIPPED=()

# ── Arguments ─────────────────────────────────────────────────────────────────
SKIP_MODELS=false

for arg in "$@"; do
  case $arg in
    --skip-models)      SKIP_MODELS=true ;;
    --civitai-token=*)  CIVITAI_TOKEN="${arg#*=}" ;;
    --hf-token=*)       HF_TOKEN="${arg#*=}" ;;
    --help)
      echo "Usage: bash setup_comfyui_supir.sh [OPTIONS]"
      echo ""
      echo "Options :"
      echo "  --skip-models           Ne télécharge pas les checkpoints"
      echo "  --civitai-token=TOKEN   Token API CivitAI"
      echo "  --hf-token=TOKEN        Token HuggingFace (si repo privé/gated)"
      echo ""
      echo "Variables d'env acceptées : HF_TOKEN, CIVITAI_TOKEN"
      exit 0 ;;
  esac
done

# Récupère aussi les tokens depuis les variables d'environnement si pas passés en arg
HF_TOKEN="${HF_TOKEN:-}"
CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"

# ── Détection du chemin ComfyUI ───────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  ComfyUI SUPIR + Moondream — Script de setup RunPod"
echo "============================================================"
echo ""

COMFY_CANDIDATES=(
  "/workspace/ComfyUI"
  "/comfyui"
  "/root/ComfyUI"
  "$HOME/ComfyUI"
)

COMFY_DIR=""
for path in "${COMFY_CANDIDATES[@]}"; do
  if [ -d "$path" ]; then
    COMFY_DIR="$path"
    break
  fi
done

if [ -z "$COMFY_DIR" ]; then
  err "ComfyUI introuvable dans les chemins habituels RunPod."
  err "Chemins testés : ${COMFY_CANDIDATES[*]}"
  err "Lance le script depuis le bon dossier ou passe le chemin en dur dans COMFY_DIR."
  exit 1
fi

log "ComfyUI détecté : $COMFY_DIR"

CUSTOM_NODES="$COMFY_DIR/custom_nodes"
MODELS="$COMFY_DIR/models"
CHECKPOINTS="$MODELS/checkpoints"
SUPIR_DIR="$MODELS/SUPIR"

# ── 1. CUSTOM NODES ───────────────────────────────────────────────────────────
echo ""
info "=== ÉTAPE 1/3 : Custom nodes ==="
echo ""

install_node() {
  local name="$1"
  local repo="$2"
  local target="$CUSTOM_NODES/$name"

  if [ -d "$target/.git" ]; then
    warn "$name déjà présent → git pull"
    git -C "$target" pull --quiet 2>/dev/null || warn "  git pull raté pour $name (continuons quand même)"
    return
  fi

  info "Clonage de $name..."
  if git clone --depth=1 "$repo" "$target" 2>/dev/null; then
    log "$name installé"
  else
    err "Échec git clone pour $name — repo inaccessible ?"
    ERRORS+=("git clone $name")
  fi
}

install_node "ComfyUI-SUPIR"                    "https://github.com/kijai/ComfyUI-SUPIR"
install_node "ComfyUI-moondream"                "https://github.com/kijai/ComfyUI-moondream"
install_node "rgthree-comfy"                    "https://github.com/rgthree/rgthree-comfy"
install_node "ComfyUI-QualityOfLifeSuit_Omar92" "https://github.com/Omar92/ComfyUI-QualityOfLifeSuit"
install_node "ComfyUI_tinyterraNodes"           "https://github.com/tinyterra/ComfyUI_tinyterraNodes"
install_node "ComfyUI-Inspire-Pack"             "https://github.com/ltdrdata/ComfyUI-Inspire-Pack"

# ── 2. DÉPENDANCES PIP ────────────────────────────────────────────────────────
echo ""
info "=== ÉTAPE 2/3 : Dépendances Python ==="
echo ""

install_requirements() {
  local label="$1"
  local req_file="$2"

  if [ ! -f "$req_file" ]; then
    warn "requirements.txt introuvable pour $label (le clone a peut-être raté)"
    return
  fi

  info "pip install pour $label..."
  if pip install -r "$req_file" --quiet 2>/dev/null; then
    log "Dépendances $label OK"
  else
    err "pip install partiel pour $label — vérifie manuellement"
    ERRORS+=("pip install $label")
  fi
}

install_requirements "SUPIR"         "$CUSTOM_NODES/ComfyUI-SUPIR/requirements.txt"
install_requirements "Inspire Pack"  "$CUSTOM_NODES/ComfyUI-Inspire-Pack/requirements.txt"

# ── 3. MODÈLES ────────────────────────────────────────────────────────────────
echo ""
info "=== ÉTAPE 3/3 : Modèles ==="
echo ""

if [ "$SKIP_MODELS" = true ]; then
  skip "Option --skip-models activée : téléchargement des checkpoints ignoré."
else
  mkdir -p "$SUPIR_DIR/Sonstige"
  mkdir -p "$CHECKPOINTS/SDXL"
  log "Dossiers modèles créés"

  # ── Fonction de téléchargement robuste ──────────────────────────────────────
  # Ne fait PAS planter le script si le téléchargement échoue
  # Gère : token HF, token CivitAI, reprise wget, fichier déjà présent
  download_file() {
    local url="$1"
    local dest="$2"
    local label="$3"
    local auth_header="${4:-}"   # optionnel : header Authorization

    if [ -f "$dest" ] && [ -s "$dest" ]; then
      skip "$label déjà présent ($(du -sh "$dest" 2>/dev/null | cut -f1)) — skip"
      return 0
    fi

    info "Téléchargement : $label"
    info "→ Vers : $dest"

    # Construction des args wget
    local wget_args=(
      --continue
      --show-progress
      --progress=bar:force:noscroll
      -O "$dest"
    )

    # Token HuggingFace via header (nouvelle méthode recommandée)
    if [ -n "$auth_header" ]; then
      wget_args+=(--header="$auth_header")
    fi

    if wget "${wget_args[@]}" "$url" 2>&1; then
      # Vérifie que le fichier n'est pas vide ou une page d'erreur HTML
      local size
      size=$(stat -c%s "$dest" 2>/dev/null || echo 0)
      if [ "$size" -lt 1000000 ]; then   # < 1 MB = suspect
        warn "$label téléchargé mais taille suspecte (${size} bytes) — vérifie le token ou l'URL"
        ERRORS+=("taille suspecte : $label")
      else
        log "$label téléchargé ($(du -sh "$dest" | cut -f1))"
      fi
    else
      rm -f "$dest"   # Supprime le fichier partiel/vide
      err "Téléchargement échoué : $label"
      SKIPPED+=("$label — échec téléchargement")
    fi
  }

  # ── SUPIR-v0F depuis HuggingFace ────────────────────────────────────────────
  # Le repo camenduru/SUPIR est public, pas besoin de token en théorie.
  # Mais si HF impose un token (gate), on l'ajoute automatiquement.
  HF_SUPIR_URL="https://huggingface.co/camenduru/SUPIR/resolve/main/SUPIR-v0F.ckpt"

  if [ -n "$HF_TOKEN" ]; then
    download_file \
      "$HF_SUPIR_URL" \
      "$SUPIR_DIR/Sonstige/SUPIR-v0F.ckpt" \
      "SUPIR-v0F.ckpt" \
      "Authorization: Bearer $HF_TOKEN"
  else
    # Tentative sans token (repo public)
    download_file \
      "$HF_SUPIR_URL" \
      "$SUPIR_DIR/Sonstige/SUPIR-v0F.ckpt" \
      "SUPIR-v0F.ckpt"
    # Si ça a foiré (fichier manquant), on avertit sans couper le script
    if [ ! -f "$SUPIR_DIR/Sonstige/SUPIR-v0F.ckpt" ]; then
      warn "SUPIR-v0F.ckpt non téléchargé. Si le repo est maintenant gated :"
      warn "  Relance avec --hf-token=TON_TOKEN"
      warn "  Ou via : hf download camenduru/SUPIR SUPIR-v0F.ckpt --local-dir $SUPIR_DIR/Sonstige/"
      SKIPPED+=("SUPIR-v0F.ckpt — token HF peut-être requis")
    fi
  fi

  # ── JuggernautXL v7 depuis CivitAI ──────────────────────────────────────────
  JUGG_DEST="$CHECKPOINTS/SDXL/juggernautXL_v7Rundiffusion.safetensors"
  JUGG_BASE_URL="https://civitai.com/api/download/models/288982"

  if [ -n "$CIVITAI_TOKEN" ]; then
    download_file \
      "${JUGG_BASE_URL}?token=${CIVITAI_TOKEN}" \
      "$JUGG_DEST" \
      "juggernautXL_v7Rundiffusion.safetensors"
  else
    warn "Pas de token CivitAI → juggernautXL non téléchargé"
    warn "  Relance avec : --civitai-token=TON_TOKEN"
    warn "  Ou manuellement : wget -O '$JUGG_DEST' '${JUGG_BASE_URL}?token=TON_TOKEN'"
    SKIPPED+=("juggernautXL — pas de token CivitAI")
  fi

  # ── Moondream2 ── géré par l'extension au 1er run ───────────────────────────
  log "Moondream2 : auto-téléchargé par l'extension au 1er lancement de ComfyUI"
fi

# ── RÉSUMÉ FINAL ──────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  RÉSUMÉ"
echo "============================================================"

if [ ${#ERRORS[@]} -eq 0 ] && [ ${#SKIPPED[@]} -eq 0 ]; then
  log "Tout s'est déroulé sans problème !"
else
  if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    err "Erreurs rencontrées (à corriger manuellement) :"
    for e in "${ERRORS[@]}"; do echo "    • $e"; done
  fi
  if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo ""
    warn "Éléments ignorés (tokens manquants ou déjà présents) :"
    for s in "${SKIPPED[@]}"; do echo "    • $s"; done
  fi
fi

echo ""
echo "  Custom nodes : $CUSTOM_NODES"
echo "  Modèles      : $MODELS"
echo ""
echo "  Structure attendue :"
echo "  $MODELS/"
echo "  ├── SUPIR/Sonstige/SUPIR-v0F.ckpt"
echo "  └── checkpoints/SDXL/juggernautXL_v7Rundiffusion.safetensors"
echo ""
echo "  → Redémarre ComfyUI pour charger les extensions"
echo "  → Charge ton workflow JSON : les nœuds devraient être verts"
echo ""

# Rappel tokens si manquants
if [ -z "$CIVITAI_TOKEN" ] || [ -z "$HF_TOKEN" ]; then
  warn "Tokens non fournis pour certains services. Pour les prochaines fois :"
  [ -z "$HF_TOKEN" ]      && warn "  HF      : export HF_TOKEN=xxx  (ou --hf-token=xxx)"
  [ -z "$CIVITAI_TOKEN" ] && warn "  CivitAI : export CIVITAI_TOKEN=xxx  (ou --civitai-token=xxx)"
fi
