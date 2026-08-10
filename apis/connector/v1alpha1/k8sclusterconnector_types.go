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

// K8sClusterConnectorParameters are the configurable fields of a K8sClusterConnector.
type K8sClusterConnectorParameters struct {
	// AccountId is the Harness Account ID.
	AccountId string `json:"accountId"`

	// OrgId is the Harness Organization ID.
	// +optional
	OrgId *string `json:"orgId,omitempty"`

	// ProjectId is the Harness Project ID.
	// +optional
	ProjectId *string `json:"projectId,omitempty"`

	// Description is the optional description of the connector.
	// +optional
	Description *string `json:"description,omitempty"`

	// CredentialType represents the credential authentication type: InheritFromDelegate or ManualConfig.
	// +kubebuilder:validation:Enum=InheritFromDelegate;ManualConfig
	CredentialType string `json:"credentialType"`

	// DelegateSelectors is a list of delegate tag selectors used when CredentialType is InheritFromDelegate.
	// +optional
	DelegateSelectors []string `json:"delegateSelectors,omitempty"`

	// MasterUrl is the URL of the Kubernetes master API server, used when CredentialType is ManualConfig.
	// +optional
	MasterUrl *string `json:"masterUrl,omitempty"`
}

// K8sClusterConnectorObservation are the observable fields of a K8sClusterConnector.
type K8sClusterConnectorObservation struct {
	// ID of the connector in Harness.
	ID string `json:"id,omitempty"`
}

// A K8sClusterConnectorSpec defines the desired state of a K8sClusterConnector.
type K8sClusterConnectorSpec struct {
	xpv2.ManagedResourceSpec `json:",inline"`
	ForProvider              K8sClusterConnectorParameters `json:"forProvider"`
}

// A K8sClusterConnectorStatus represents the observed state of a K8sClusterConnector.
type K8sClusterConnectorStatus struct {
	xpv2.ManagedResourceStatus `json:",inline"`
	AtProvider                 K8sClusterConnectorObservation `json:"atProvider,omitempty"`
}

// +kubebuilder:object:root=true

// A K8sClusterConnector is an example API type.
// +kubebuilder:printcolumn:name="READY",type="string",JSONPath=".status.conditions[?(@.type=='Ready')].status"
// +kubebuilder:printcolumn:name="SYNCED",type="string",JSONPath=".status.conditions[?(@.type=='Synced')].status"
// +kubebuilder:printcolumn:name="EXTERNAL-NAME",type="string",JSONPath=".metadata.annotations.crossplane\\.io/external-name"
// +kubebuilder:printcolumn:name="AGE",type="date",JSONPath=".metadata.creationTimestamp"
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,categories={crossplane,managed,harness}
type K8sClusterConnector struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   K8sClusterConnectorSpec   `json:"spec"`
	Status K8sClusterConnectorStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// K8sClusterConnectorList contains a list of K8sClusterConnector
type K8sClusterConnectorList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []K8sClusterConnector `json:"items"`
}

// K8sClusterConnector type metadata.
var (
	K8sClusterConnectorKind             = reflect.TypeOf(K8sClusterConnector{}).Name()
	K8sClusterConnectorGroupKind        = schema.GroupKind{Group: Group, Kind: K8sClusterConnectorKind}.String()
	K8sClusterConnectorKindAPIVersion   = K8sClusterConnectorKind + "." + SchemeGroupVersion.String()
	K8sClusterConnectorGroupVersionKind = SchemeGroupVersion.WithKind(K8sClusterConnectorKind)
)

func init() {
	SchemeBuilder.Register(&K8sClusterConnector{}, &K8sClusterConnectorList{})
}
