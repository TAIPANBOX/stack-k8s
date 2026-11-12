# The console's preview key, and wardryx's copy of its public half (the recipient), minted once when the
# cluster holds neither. Sourced by deploy.sh, cloud/gcp/deploy-gcp.sh and cloud/aws/deploy-aws.sh, not run.
# CLAUDE.md invariant 91.
#
# `@decided 2026-11-12` (paraphrased): a person approving a held tool call is shown its arguments, taken from
# wardryx and never from model text, sealed so that only the console can open them. wardryx seals each preview
# to the console's public key (WARDRYX_PREVIEW_RECIPIENT), and the console opens it with the private key only
# it holds (GENARYX_PREVIEW_KEY_FILE). This file makes that pair; it never rewrites it.
#
# WHY A POD AND NOT OPENSSL. The key is X-Wing (ML-KEM-768 with X25519, HPKE KEM 0x647a), which openssl does
# not make, and the wardryx image is distroless. The console image has the generator (`genaryx-web
# preview-key`) and a shell, so a one-off pod runs it on that image, in this namespace, under the same
# restricted security context the console runs under. The private key is read back with `kubectl exec`, which
# is a stream and not the container's log, so it reaches no log file and no log shipper. The pod's /work is a
# memory-backed emptyDir, gone with the pod.
#
# Needs in scope, from the caller: die(), k_ (its kubectl runner, given ONE argument string) and secret_doc
# from lib/secret-doc.sh. Writes nothing but the two objects below, a one-off pod it deletes on every path, and
# a private temporary directory (mode 0700) that holds the key for the length of one call.
#
# WHAT A RUN DOES, by what the cluster holds:
#   neither object     runs the pod, creates the Secret console-preview-key (key preview.key) and the ConfigMap
#                      wardryx-preview-recipient (key recipient), then restarts wardryx, which reads its
#                      recipient at start.
#   both objects       nothing. The key is never rewritten: a preview sealed to the old key could not be opened.
#   one of the two     refuses. A recipient the console's key does not match seals previews nobody can open.
#   no console         nothing, and says so. Without a console there is no one to show a preview to, and wardryx
#                      records each hold's preview as off.

PREVIEW_NS="${PREVIEW_NS:-agent-stack}"
PREVIEW_SECRET="console-preview-key"
PREVIEW_CM="wardryx-preview-recipient"
PREVIEW_POD="console-preview-mint"

# preview_mint_fail DIR MESSAGE: delete the pod and the private directory, then refuse.
preview_mint_fail() {
  k_ "-n $PREVIEW_NS delete pod/$PREVIEW_POD --ignore-not-found --wait=false" >/dev/null 2>&1 || true
  rm -rf "$1"
  die "$2"
}

preview_mint_settle() {
  local have secret_there=no cm_there=no img dir recipient i
  have="$(k_ "-n $PREVIEW_NS get secret/$PREVIEW_SECRET configmap/$PREVIEW_CM --ignore-not-found -o name" \
    | tr '\n' ' ')" || die "could not ask the cluster whether the preview key exists"
  case " $have " in *" secret/$PREVIEW_SECRET "*) secret_there=yes ;; esac
  case " $have " in *" configmap/$PREVIEW_CM "*) cm_there=yes ;; esac

  if [ "$secret_there" = yes ] && [ "$cm_there" = yes ]; then
    printf '   preview key: kept (%s and %s are both in %s)\n' "$PREVIEW_SECRET" "$PREVIEW_CM" "$PREVIEW_NS"
    return 0
  fi
  if [ "$secret_there" = yes ] || [ "$cm_there" = yes ]; then
    die "the preview key and its recipient are not both in $PREVIEW_NS (have: ${have:-none}). A recipient the console's key does not match seals previews nobody can open, so nothing was changed. Delete the one that is there, then run the deploy again."
  fi

  img="$(k_ "-n $PREVIEW_NS get deployment/genaryx-console --ignore-not-found -o jsonpath='{.spec.template.spec.containers[*].image}'")" \
    || die "could not read the console's image"
  local word found=""
  for word in $img; do
    case "$word" in *genaryx-console*) found="$word"; break ;; esac
  done
  img="$found"
  if [ -z "$img" ]; then
    printf '   preview key: none (no console in %s, so wardryx records each preview as off)\n' "$PREVIEW_NS"
    return 0
  fi

  dir="$(mktemp -d)" || die "could not create a private directory for the preview key"
  chmod 700 "$dir"
  k_ "-n $PREVIEW_NS delete pod/$PREVIEW_POD --ignore-not-found" >/dev/null 2>&1 || true
  cat <<POD | k_ "-n $PREVIEW_NS create -f -" >/dev/null || preview_mint_fail "$dir" "could not start the pod that makes the preview key"
apiVersion: v1
kind: Pod
metadata:
  name: $PREVIEW_POD
  labels: { app: console-preview-mint }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  enableServiceLinks: false
  activeDeadlineSeconds: 300
  securityContext:
    runAsNonRoot: true
    runAsUser: 20030
    runAsGroup: 20030
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: mint
      image: $img
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "umask 077 && /usr/local/bin/genaryx-web preview-key --out /work/preview.key > /work/recipient && sleep 240"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { memory: 128Mi }
      volumeMounts: [{ name: work, mountPath: /work }]
  volumes:
    - name: work
      emptyDir: { medium: Memory, sizeLimit: 1Mi }
POD
  k_ "-n $PREVIEW_NS wait --for=condition=Ready pod/$PREVIEW_POD --timeout=180s" >/dev/null \
    || preview_mint_fail "$dir" "the pod that makes the preview key did not start (image $img)"
  recipient=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    recipient="$(k_ "-n $PREVIEW_NS exec $PREVIEW_POD -- cat /work/recipient" 2>/dev/null)" && [ -n "$recipient" ] && break
    sleep "${PREVIEW_MINT_POLL:-2}"
  done
  # The whole value, one line of base64url: it is written into a ConfigMap document and wardryx's environment.
  [[ "$recipient" =~ ^hpke:647a:[A-Za-z0-9_-]+$ ]] \
    || preview_mint_fail "$dir" "the console image printed no X-Wing recipient (a console older than genaryx #158 has no preview-key command)"
  ( umask 077; k_ "-n $PREVIEW_NS exec $PREVIEW_POD -- cat /work/preview.key" >"$dir/preview.key" ) \
    || preview_mint_fail "$dir" "could not read the preview key back from its pod"
  [ "$(wc -l <"$dir/preview.key" | tr -d ' ')" = 1 ] && grep -qE '^hpke-private:647a:[A-Za-z0-9_-]+$' "$dir/preview.key" \
    || preview_mint_fail "$dir" "what came back from the pod is not an X-Wing preview key"
  k_ "-n $PREVIEW_NS delete pod/$PREVIEW_POD --wait=false" >/dev/null 2>&1 || true

  {
    secret_doc "$PREVIEW_SECRET" "preview.key=@$dir/preview.key"
    printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\ndata:\n  recipient: %s\n' \
      "$PREVIEW_CM" "$recipient"
  } | k_ "-n $PREVIEW_NS create -f -" >/dev/null \
    || preview_mint_fail "$dir" "could not create the preview key and its recipient in $PREVIEW_NS"
  rm -rf "$dir"
  # wardryx reads WARDRYX_PREVIEW_RECIPIENT at start, from an optional ConfigMap reference, so a pod that
  # started before the mint has none. One restart, on the first mint only.
  k_ "-n $PREVIEW_NS rollout restart deployment/wardryx" >/dev/null \
    || die "the preview key was minted, but wardryx could not be restarted to read its recipient. Run: kubectl -n $PREVIEW_NS rollout restart deployment/wardryx"
  printf '   preview key: minted (%s, and %s with the public half). The private key was never printed.\n' \
    "$PREVIEW_SECRET" "$PREVIEW_CM"
}
