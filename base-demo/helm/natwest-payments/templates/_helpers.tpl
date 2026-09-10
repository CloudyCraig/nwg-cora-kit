{{/*
Common labels for a service.
*/}}
{{- define "natwest.labels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .release }}
app.kubernetes.io/component: {{ .tier }}
app.kubernetes.io/part-of: natwest-payments
app.kubernetes.io/managed-by: Helm
{{- end -}}

{{/*
Resolve per-service value or fall back to global default.
Usage: include "natwest.value" (dict "svc" $svc "key" "latencyMsMean" "default" $default)
*/}}
{{- define "natwest.value" -}}
{{- if hasKey .svc .key -}}
{{- index .svc .key -}}
{{- else -}}
{{- .default -}}
{{- end -}}
{{- end -}}
