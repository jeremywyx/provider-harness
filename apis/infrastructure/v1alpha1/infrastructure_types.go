/*
Copyright 2025 The Crossplane Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package v1alpha1

import (
	"reflect"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"

	xpv2 "github.com/crossplane/crossplane/apis/v2/core/v2"
)

// InfrastructureParameters are the configurable fields of a Infrastructure.
type InfrastructureParameters struct {
	// AccountId is the Harness Account ID.
	AccountId string `json:"accountId"`

	// OrgId is the Harness Organization ID.
	// +optional
	OrgId *string `json:"orgId,omitempty"`

	// ProjectId is the Harness Project ID.
	// +optional
	ProjectId *string `json:"projectId,omitempty"`

	// EnvId is the Harness Environment identifier this infrastructure belongs to.
	EnvId string `json:"envId"`

	// Type represents the infrastructure type, e.g. KubernetesDirect.
	Type string `json:"type"`

	// DeploymentType represents the deployment type, e.g. Kubernetes.
	DeploymentType string `json:"deploymentType"`

	// ConnectorRef is the Harness Connector identifier to use.
	ConnectorRef string `json:"connectorRef"`

	// Namespace is the target Kubernetes namespace in the cluster.
	Namespace string `json:"namespace"`

	// Yaml is an optional raw Harness Infrastructure Definition YAML string override.
	// +optional
	Yaml *string `json:"yaml,omitempty"`

	// AllowSimultaneousDeployments allows simultaneous deployments.
	// +optional
	AllowSimultaneousDeployments *bool `json:"allowSimultaneousDeployments,omitempty"`
}

// InfrastructureObservation are the observable fields of a Infrastructure.
type InfrastructureObservation struct {
	// ID of the infrastructure in Harness.
	ID string `json:"id,omitempty"`
}

// A InfrastructureSpec defines the desired state of a Infrastructure.
type InfrastructureSpec struct {
	xpv2.ManagedResourceSpec `json:",inline"`
	ForProvider              InfrastructureParameters `json:"forProvider"`
}

// A InfrastructureStatus represents the observed state of a Infrastructure.
type InfrastructureStatus struct {
	xpv2.ManagedResourceStatus `json:",inline"`
	AtProvider                 InfrastructureObservation `json:"atProvider,omitempty"`
}

// +kubebuilder:object:root=true

// A Infrastructure is an example API type.
// +kubebuilder:printcolumn:name="READY",type="string",JSONPath=".status.conditions[?(@.type=='Ready')].status"
// +kubebuilder:printcolumn:name="SYNCED",type="string",JSONPath=".status.conditions[?(@.type=='Synced')].status"
// +kubebuilder:printcolumn:name="EXTERNAL-NAME",type="string",JSONPath=".metadata.annotations.crossplane\\.io/external-name"
// +kubebuilder:printcolumn:name="AGE",type="date",JSONPath=".metadata.creationTimestamp"
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,categories={crossplane,managed,harness}
type Infrastructure struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   InfrastructureSpec   `json:"spec"`
	Status InfrastructureStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// InfrastructureList contains a list of Infrastructure
type InfrastructureList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Infrastructure `json:"items"`
}

// Infrastructure type metadata.
var (
	InfrastructureKind             = reflect.TypeOf(Infrastructure{}).Name()
	InfrastructureGroupKind        = schema.GroupKind{Group: Group, Kind: InfrastructureKind}.String()
	InfrastructureKindAPIVersion   = InfrastructureKind + "." + SchemeGroupVersion.String()
	InfrastructureGroupVersionKind = SchemeGroupVersion.WithKind(InfrastructureKind)
)

func init() {
	SchemeBuilder.Register(&Infrastructure{}, &InfrastructureList{})
}
