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

// DelegateTokenParameters are the configurable fields of a DelegateToken.
type DelegateTokenParameters struct {
	// AccountId is the Harness Account ID.
	AccountId string `json:"accountId"`

	// OrgId is the Harness Organization ID.
	// +optional
	OrgId *string `json:"orgId,omitempty"`

	// ProjectId is the Harness Project ID.
	// +optional
	ProjectId *string `json:"projectId,omitempty"`

	// TokenStatus represents whether the token is ACTIVE or REVOKED.
	// +optional
	// +kubebuilder:validation:Enum=ACTIVE;REVOKED
	TokenStatus *string `json:"tokenStatus,omitempty"`
}

// DelegateTokenObservation are the observable fields of a DelegateToken.
type DelegateTokenObservation struct {
	// ID of the token in Harness.
	ID string `json:"id,omitempty"`

	// CreatedAt is the timestamp when the token was created.
	CreatedAt *int64 `json:"createdAt,omitempty"`
}

// A DelegateTokenSpec defines the desired state of a DelegateToken.
type DelegateTokenSpec struct {
	xpv2.ManagedResourceSpec `json:",inline"`
	ForProvider              DelegateTokenParameters `json:"forProvider"`
}

// A DelegateTokenStatus represents the observed state of a DelegateToken.
type DelegateTokenStatus struct {
	xpv2.ManagedResourceStatus `json:",inline"`
	AtProvider                 DelegateTokenObservation `json:"atProvider,omitempty"`
}

// +kubebuilder:object:root=true

// A DelegateToken is an example API type.
// +kubebuilder:printcolumn:name="READY",type="string",JSONPath=".status.conditions[?(@.type=='Ready')].status"
// +kubebuilder:printcolumn:name="SYNCED",type="string",JSONPath=".status.conditions[?(@.type=='Synced')].status"
// +kubebuilder:printcolumn:name="EXTERNAL-NAME",type="string",JSONPath=".metadata.annotations.crossplane\\.io/external-name"
// +kubebuilder:printcolumn:name="AGE",type="date",JSONPath=".metadata.creationTimestamp"
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,categories={crossplane,managed,harness}
type DelegateToken struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   DelegateTokenSpec   `json:"spec"`
	Status DelegateTokenStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// DelegateTokenList contains a list of DelegateToken
type DelegateTokenList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []DelegateToken `json:"items"`
}

// DelegateToken type metadata.
var (
	DelegateTokenKind             = reflect.TypeOf(DelegateToken{}).Name()
	DelegateTokenGroupKind        = schema.GroupKind{Group: Group, Kind: DelegateTokenKind}.String()
	DelegateTokenKindAPIVersion   = DelegateTokenKind + "." + SchemeGroupVersion.String()
	DelegateTokenGroupVersionKind = SchemeGroupVersion.WithKind(DelegateTokenKind)
)

func init() {
	SchemeBuilder.Register(&DelegateToken{}, &DelegateTokenList{})
}
