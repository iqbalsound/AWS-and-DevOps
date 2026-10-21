#!/usr/bin/env bash
# =============================================================================
# cleanup-azure.sh  -  removes EVERYTHING the Azure capstone created
# Run in Azure Cloud Shell (Bash):  export STUDENT_ID=iqbal01 ; ./cleanup-azure.sh
# Skip the question with:  CONFIRM=yes ./cleanup-azure.sh
# =============================================================================
set -uo pipefail
say() { echo "==> $*"; }; ok() { echo "[ OK ] $*"; }; warn() { echo "[WARN] $*"; }; die() { echo "[FAIL] $*" >&2; exit 1; }
STUDENT_ID="${STUDENT_ID:-}"
[[ "$STUDENT_ID" =~ ^[a-z0-9]{3,8}$ ]] || die "Set STUDENT_ID first, e.g.: export STUDENT_ID=iqbal01"
az account show >/dev/null 2>&1 || die "Not signed in to Azure."
P="cap-$STUDENT_ID"; RG="rg-$P"; WORK="$HOME/capstone-azure-$STUDENT_ID"
[ -f "$WORK/state.env" ] && . "$WORK/state.env"
if ! az group exists -n "$RG" | grep -q true; then
  warn "Resource group $RG does not exist (already deleted?). Checking for leftovers only."
else
  say "These resources will be deleted:"; az resource list -g "$RG" --query '[].{name:name,type:type}' -o table
  if [ "${CONFIRM:-}" != yes ]; then
    read -r -p "Type the resource group name ($RG) to confirm: " ans; [ "$ans" = "$RG" ] || die "Not confirmed. Nothing was deleted."
  fi
  say "Removing resource locks (a CanNotDelete lock blocks deletion)"
  for id in $(az lock list -g "$RG" --query '[].id' -o tsv); do az lock delete --ids "$id" && ok "lock removed"; done
  say "Deleting resource group $RG (VMs, disks, public IPs, NSG, VNet, Key Vault, alerts) ..."
  az group delete -n "$RG" --yes --no-wait
  az group wait -n "$RG" --deleted --timeout 1500 2>/dev/null; ok "Resource group deleted"
fi
say "Purging soft-deleted Key Vaults of this student (frees the name, stops retention)"
for kv in $(az keyvault list-deleted --query "[?starts_with(name,'kv${STUDENT_ID}')].name" -o tsv); do
  loc=$(az keyvault list-deleted --query "[?name=='$kv'].properties.location | [0]" -o tsv)
  az keyvault purge --name "$kv" --location "$loc" >/dev/null 2>&1 && ok "purged $kv" || warn "could not purge $kv (check Key Vault > Manage deleted vaults)"
done
say "Final check"
left=$(az resource list --tag project=capstone --query "[?tags.owner=='$STUDENT_ID'] | length(@)" -o tsv)
if az group exists -n "$RG" | grep -q false && [ "${left:-0}" = 0 ]; then ok "CLEAN: no resource group and no tagged resources left for $STUDENT_ID"; else warn "Something is left. Portal > All resources, filter tag project=capstone."; fi
[ -f "$WORK/timeline.log" ] && cp "$WORK/timeline.log" "$HOME/capstone-timeline-$STUDENT_ID.log"
rm -rf "$WORK"; ok "Local work folder removed (timeline copy kept in your home folder)"
echo "Still to check by hand: Cost Management + Billing > Cost analysis (should show about 0), and any Action Group e-mails."
echo "Cloud Shell's own storage account (rg cloud-shell-storage-*) is NOT part of this lab. Delete it at the end of the course."
