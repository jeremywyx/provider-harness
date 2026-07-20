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

// DelegateParameters are the configurable fields of a Delegate.
type DelegateParameters struct {
	// DelegateIdentifier is the unique identifier of the delegate.
	DelegateIdentifier string `json:"delegateIdentifier"`

	// AccountId is the Harness Account ID.
	AccountId string `json:"accountId"`

	// OrgId is the Harness Organization ID.
	// +optional
	OrgId *string `json:"orgId,omitempty"`

	// ProjectId is the Harness Project ID.
	// +optional
	ProjectId *string `json:"projectId,omitempty"`
}

// DelegateObservation are the observable fields of a Delegate.
type DelegateObservation struct {
	// ID of the delegate.
	ID string `json:"id,omitempty"`

	// Hostname of the delegate.
	Hostname string `json:"hostname,omitempty"`

	// Status of the delegate (e.g. ENABLED, WAITING_FOR_APPROVAL, etc).
	Status string `json:"status,omitempty"`

	// Version of the delegate.
	Version string `json:"version,omitempty"`

	// DelegateType of the delegate (e.g. KUBERNETES, DOCKER).
	DelegateType string `json:"delegateType,omitempty"`
}

// A DelegateSpec defines the desired state of a Delegate.
type DelegateSpec struct {
	xpv2.ManagedResourceSpec `json:",inline"`
	ForProvider              DelegateParameters `json:"forProvider"`
}

// A DelegateStatus represents the observed state of a Delegate.
type DelegateStatus struct {
	xpv2.ManagedResourceStatus `json:",inline"`
	AtProvider                 DelegateObservation `json:"atProvider,omitempty"`
}

// +kubebuilder:object:root=true

// A Delegate is an example API type.
// +kubebuilder:printcolumn:name="READY",type="string",JSONPath=".status.conditions[?(@.type=='Ready')].status"
// +kubebuilder:printcolumn:name="SYNCED",type="string",JSONPath=".status.conditions[?(@.type=='Synced')].status"
// +kubebuilder:printcolumn:name="EXTERNAL-NAME",type="string",JSONPath=".metadata.annotations.crossplane\\.io/external-name"
// +kubebuilder:printcolumn:name="AGE",type="date",JSONPath=".metadata.creationTimestamp"
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,categories={crossplane,managed,harness}
type Delegate struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   DelegateSpec   `json:"spec"`
	Status DelegateStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// DelegateList contains a list of Delegate
type DelegateList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Delegate `json:"items"`
}

// Delegate type metadata.
var (
	DelegateKind             = reflect.TypeOf(Delegate{}).Name()
	DelegateGroupKind        = schema.GroupKind{Group: Group, Kind: DelegateKind}.String()
	DelegateKindAPIVersion   = DelegateKind + "." + SchemeGroupVersion.String()
	DelegateGroupVersionKind = SchemeGroupVersion.WithKind(DelegateKind)
)

func init() {
	SchemeBuilder.Register(&Delegate{}, &DelegateList{})
}
