{{- define "brewq-monitoring.labels" -}}
app.kubernetes.io/name: brewq
app.kubernetes.io/instance: brewq
app.kubernetes.io/part-of: brewq
release: kps
{{- end -}}
