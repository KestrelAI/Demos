{{/*
Expand the name of the chart.
*/}}
{{- define "mig-fragmentation-demo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "mig-fragmentation-demo.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "mig-fragmentation-demo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mig-fragmentation-demo.labels" -}}
helm.sh/chart: {{ include "mig-fragmentation-demo.chart" . }}
{{ include "mig-fragmentation-demo.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- range $key, $value := .Values.labels }}
{{ $key }}: {{ $value | quote }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mig-fragmentation-demo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mig-fragmentation-demo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "mig-fragmentation-demo.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mig-fragmentation-demo.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Common tolerations
*/}}
{{- define "mig-fragmentation-demo.tolerations" -}}
{{- if .Values.tolerations }}
tolerations:
{{- toYaml .Values.tolerations | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Common node selector
*/}}
{{- define "mig-fragmentation-demo.nodeSelector" -}}
{{- if .Values.nodeSelector }}
nodeSelector:
{{- toYaml .Values.nodeSelector | nindent 2 }}
{{- end }}
{{- end }}
