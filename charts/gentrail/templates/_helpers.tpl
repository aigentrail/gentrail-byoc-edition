{{/* Canonical name for a sub-component. */}}
{{- define "gentrail.name" -}}
{{- printf "gentrail-%s" .component -}}
{{- end -}}

{{/* Standard labels applied to every resource. */}}
{{- define "gentrail.labels" -}}
app.kubernetes.io/name: gentrail
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Selector labels. */}}
{{- define "gentrail.selectorLabels" -}}
app.kubernetes.io/name: gentrail
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Image reference. */}}
{{- define "gentrail.image" -}}
{{ .Values.image.registry }}/{{ .component }}:{{ .Values.image.tag }}
{{- end -}}

{{/* Pull-secret block (only emits imagePullSecrets if non-empty). */}}
{{- define "gentrail.imagePullSecrets" -}}
{{- if .Values.image.pullSecret -}}
imagePullSecrets:
  - name: {{ .Values.image.pullSecret }}
{{- end -}}
{{- end -}}

{{/* Local-mode env: point at in-cluster DynamoDB-local with dummy creds. Empty
     ddb.endpoint (prod) emits nothing, so the services use real DDB via IRSA. */}}
{{- define "gentrail.localEnv" -}}
{{- if .Values.ddb.endpoint }}
- name: AWS_ENDPOINT_URL_DYNAMODB
  value: {{ .Values.ddb.endpoint | quote }}
- name: AWS_ACCESS_KEY_ID
  value: "local"
- name: AWS_SECRET_ACCESS_KEY
  value: "local"
{{- end }}
{{- end -}}

{{/* IRSA without the pod-identity webhook: a projected SA token (audience
     sts.amazonaws.com, signed by the cluster's OIDC issuer) plus the env the
     AWS SDK reads to call AssumeRoleWithWebIdentity. Pass the role ARN. */}}
{{- define "gentrail.irsaEnv" -}}
- name: AWS_ROLE_ARN
  value: {{ . | quote }}
- name: AWS_WEB_IDENTITY_TOKEN_FILE
  value: /var/run/secrets/eks.amazonaws.com/serviceaccount/token
{{- end -}}

{{- define "gentrail.irsaTokenMount" -}}
- name: aws-iam-token
  mountPath: /var/run/secrets/eks.amazonaws.com/serviceaccount
  readOnly: true
{{- end -}}

{{- define "gentrail.irsaTokenVolume" -}}
- name: aws-iam-token
  projected:
    sources:
      - serviceAccountToken:
          audience: sts.amazonaws.com
          expirationSeconds: 86400
          path: token
{{- end -}}

{{/* License delivered as a mounted secret so the kubelet propagates updates
     to running pods and the services hot-reload without a restart. */}}
{{- define "gentrail.licenseEnv" -}}
- name: LICENSE_JWT_FILE
  value: /etc/gentrail/license/jwt
{{- end }}

{{- define "gentrail.licenseMount" -}}
- name: license
  mountPath: /etc/gentrail/license
  readOnly: true
{{- end }}

{{- define "gentrail.licenseVolume" -}}
- name: license
  secret:
    secretName: {{ .Values.license.secretRef }}
{{- end }}
