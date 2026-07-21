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

package k8sclusterconnector

import (
	"context"

	"github.com/crossplane/crossplane-runtime/v2/pkg/feature"
	"github.com/crossplane/crossplane-runtime/v2/pkg/meta"
	xpv2 "github.com/crossplane/crossplane/apis/v2/core/v2"

	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/crossplane/crossplane-runtime/v2/pkg/controller"
	"github.com/crossplane/crossplane-runtime/v2/pkg/errors"
	"github.com/crossplane/crossplane-runtime/v2/pkg/event"
	"github.com/crossplane/crossplane-runtime/v2/pkg/ratelimiter"
	"github.com/crossplane/crossplane-runtime/v2/pkg/reconciler/managed"
	"github.com/crossplane/crossplane-runtime/v2/pkg/resource"
	"github.com/crossplane/crossplane-runtime/v2/pkg/statemetrics"

	v1alpha1 "github.com/jeremywyx/provider-harness/apis/connector/v1alpha1"
	apisv1alpha1 "github.com/jeremywyx/provider-harness/apis/v1alpha1"
	"github.com/jeremywyx/provider-harness/internal/clients"
)

const (
	errTrackPCUsage = "cannot track ProviderConfig usage"
	errGetPC        = "cannot get ProviderConfig"
	errGetCPC       = "cannot get ClusterProviderConfig"
	errGetCreds     = "cannot get credentials"

	errNewClient = "cannot create new Service"
)

var (
	newHarnessClient = func(apiKey []byte, accountID string, endpoint string) (interface{}, error) {
		return clients.NewClient(string(apiKey), accountID, endpoint), nil
	}
)

// SetupGated adds a controller that reconciles K8sClusterConnector managed resources with safe-start support.
func SetupGated(mgr ctrl.Manager, o controller.Options) error {
	o.Gate.Register(func() {
		if err := Setup(mgr, o); err != nil {
			panic(errors.Wrap(err, "cannot setup K8sClusterConnector controller"))
		}
	}, v1alpha1.K8sClusterConnectorGroupVersionKind)
	return nil
}

// Setup adds a controller that reconciles K8sClusterConnector managed resources.
func Setup(mgr ctrl.Manager, o controller.Options) error {
	name := managed.ControllerName(v1alpha1.K8sClusterConnectorGroupKind)

	opts := []managed.ReconcilerOption{
		managed.WithTypedExternalConnector[*v1alpha1.K8sClusterConnector](&connector{
			kube:         mgr.GetClient(),
			usage:        resource.NewProviderConfigUsageTracker(mgr.GetClient(), &apisv1alpha1.ProviderConfigUsage{}),
			newServiceFn: newHarnessClient}),
		managed.WithLogger(o.Logger.WithValues("controller", name)),
		managed.WithPollInterval(o.PollInterval),
		managed.WithRecorder(event.NewAPIRecorder(mgr.GetEventRecorderFor(name))), //nolint:staticcheck
	}

	if o.Features.Enabled(feature.EnableBetaManagementPolicies) {
		opts = append(opts, managed.WithManagementPolicies())
	}

	if o.Features.Enabled(feature.EnableAlphaChangeLogs) {
		opts = append(opts, managed.WithChangeLogger(o.ChangeLogOptions.ChangeLogger))
	}

	if o.MetricOptions != nil {
		opts = append(opts, managed.WithMetricRecorder(o.MetricOptions.MRMetrics))
	}

	if o.MetricOptions != nil && o.MetricOptions.MRStateMetrics != nil {
		stateMetricsRecorder := statemetrics.NewMRStateRecorder(
			mgr.GetClient(), o.Logger, o.MetricOptions.MRStateMetrics, &v1alpha1.K8sClusterConnectorList{}, o.MetricOptions.PollStateMetricInterval,
		)
		if err := mgr.Add(stateMetricsRecorder); err != nil {
			return errors.Wrap(err, "cannot register MR state metrics recorder for kind v1alpha1.K8sClusterConnectorList")
		}
	}

	r := managed.NewReconciler(mgr, resource.ManagedKind(v1alpha1.K8sClusterConnectorGroupVersionKind), opts...)

	return ctrl.NewControllerManagedBy(mgr).
		Named(name).
		WithOptions(o.ForControllerRuntime()).
		WithEventFilter(resource.DesiredStateChanged()).
		For(&v1alpha1.K8sClusterConnector{}).
		Complete(ratelimiter.NewReconciler(name, r, o.GlobalRateLimiter))
}

type connector struct {
	kube         client.Client
	usage        *resource.ProviderConfigUsageTracker
	newServiceFn func(creds []byte, accountID string, endpoint string) (interface{}, error)
}

func (c *connector) Connect(ctx context.Context, cr *v1alpha1.K8sClusterConnector) (managed.TypedExternalClient[*v1alpha1.K8sClusterConnector], error) {
	if err := c.usage.Track(ctx, cr); err != nil {
		return nil, errors.Wrap(err, errTrackPCUsage)
	}

	var cd apisv1alpha1.ProviderCredentials
	var accountID string
	var endpoint string

	ref := cr.GetProviderConfigReference()

	switch ref.Kind {
	case "ProviderConfig":
		pc := &apisv1alpha1.ProviderConfig{}
		if err := c.kube.Get(ctx, types.NamespacedName{Name: ref.Name, Namespace: cr.GetNamespace()}, pc); err != nil {
			return nil, errors.Wrap(err, errGetPC)
		}
		cd = pc.Spec.Credentials
		accountID = pc.Spec.AccountId
		if pc.Spec.Endpoint != nil {
			endpoint = *pc.Spec.Endpoint
		}
	case "ClusterProviderConfig":
		cpc := &apisv1alpha1.ClusterProviderConfig{}
		if err := c.kube.Get(ctx, types.NamespacedName{Name: ref.Name}, cpc); err != nil {
			return nil, errors.Wrap(err, errGetCPC)
		}
		cd = cpc.Spec.Credentials
		accountID = cpc.Spec.AccountId
		if cpc.Spec.Endpoint != nil {
			endpoint = *cpc.Spec.Endpoint
		}
	default:
		return nil, errors.Errorf("unsupported provider config kind: %s", ref.Kind)
	}
	data, err := resource.CommonCredentialExtractor(ctx, cd.Source, c.kube, cd.CommonCredentialSelectors)
	if err != nil {
		return nil, errors.Wrap(err, errGetCreds)
	}

	svc, err := c.newServiceFn(data, accountID, endpoint)
	if err != nil {
		return nil, errors.Wrap(err, errNewClient)
	}

	return &external{service: svc}, nil
}

type external struct {
	service interface{}
}

func generateConnectorPayload(cr *v1alpha1.K8sClusterConnector) *clients.ConnectorData {
	orgID := ""
	if cr.Spec.ForProvider.OrgId != nil {
		orgID = *cr.Spec.ForProvider.OrgId
	}
	projectID := ""
	if cr.Spec.ForProvider.ProjectId != nil {
		projectID = *cr.Spec.ForProvider.ProjectId
	}
	description := ""
	if cr.Spec.ForProvider.Description != nil {
		description = *cr.Spec.ForProvider.Description
	}

	identifier := meta.GetExternalName(cr)
	if identifier == "" {
		identifier = cr.GetName()
	}

	var spec any
	if cr.Spec.ForProvider.CredentialType == "InheritFromDelegate" {
		spec = clients.K8sClusterConnectorSpec{
			Credential: clients.CredentialWrapper{
				Type: "InheritFromDelegate",
				Spec: clients.InheritFromDelegateSpec{
					DelegateSelectors: cr.Spec.ForProvider.DelegateSelectors,
				},
			},
		}
	} else {
		masterUrl := ""
		if cr.Spec.ForProvider.MasterUrl != nil {
			masterUrl = *cr.Spec.ForProvider.MasterUrl
		}
		spec = clients.K8sClusterConnectorSpec{
			Credential: clients.CredentialWrapper{
				Type: "ManualConfig",
				Spec: clients.ManualConfigSpec{
					MasterUrl: masterUrl,
				},
			},
		}
	}

	return &clients.ConnectorData{
		Name:              cr.GetName(),
		Identifier:        identifier,
		Description:       description,
		OrgIdentifier:     orgID,
		ProjectIdentifier: projectID,
		Type:              "K8sCluster",
		Spec:              spec,
	}
}

func (c *external) Observe(ctx context.Context, cr *v1alpha1.K8sClusterConnector) (managed.ExternalObservation, error) {
	client := c.service.(*clients.Client)
	connectorName := meta.GetExternalName(cr)
	if connectorName == "" {
		connectorName = cr.GetName()
	}

	orgID := ""
	if cr.Spec.ForProvider.OrgId != nil {
		orgID = *cr.Spec.ForProvider.OrgId
	}
	projectID := ""
	if cr.Spec.ForProvider.ProjectId != nil {
		projectID = *cr.Spec.ForProvider.ProjectId
	}

	connector, err := client.GetConnector(ctx, orgID, projectID, connectorName)
	if err != nil {
		return managed.ExternalObservation{}, err
	}

	if connector == nil {
		return managed.ExternalObservation{
			ResourceExists: false,
		}, nil
	}

	meta.SetExternalName(cr, connector.Identifier)
	cr.Status.AtProvider.ID = connector.Identifier
	cr.SetConditions(xpv2.Available())

	upToDate := true

	return managed.ExternalObservation{
		ResourceExists:    true,
		ResourceUpToDate:  upToDate,
		ConnectionDetails: managed.ConnectionDetails{},
	}, nil
}

func (c *external) Create(ctx context.Context, cr *v1alpha1.K8sClusterConnector) (managed.ExternalCreation, error) {
	client := c.service.(*clients.Client)
	orgID := ""
	if cr.Spec.ForProvider.OrgId != nil {
		orgID = *cr.Spec.ForProvider.OrgId
	}
	projectID := ""
	if cr.Spec.ForProvider.ProjectId != nil {
		projectID = *cr.Spec.ForProvider.ProjectId
	}

	payload := generateConnectorPayload(cr)
	connector, err := client.CreateConnector(ctx, orgID, projectID, payload)
	if err != nil {
		return managed.ExternalCreation{}, err
	}

	meta.SetExternalName(cr, connector.Identifier)
	cr.Status.AtProvider.ID = connector.Identifier

	return managed.ExternalCreation{}, nil
}

func (c *external) Update(ctx context.Context, cr *v1alpha1.K8sClusterConnector) (managed.ExternalUpdate, error) {
	client := c.service.(*clients.Client)
	orgID := ""
	if cr.Spec.ForProvider.OrgId != nil {
		orgID = *cr.Spec.ForProvider.OrgId
	}
	projectID := ""
	if cr.Spec.ForProvider.ProjectId != nil {
		projectID = *cr.Spec.ForProvider.ProjectId
	}

	payload := generateConnectorPayload(cr)
	_, err := client.UpdateConnector(ctx, orgID, projectID, cr.Status.AtProvider.ID, payload)
	if err != nil {
		return managed.ExternalUpdate{}, err
	}

	return managed.ExternalUpdate{}, nil
}

func (c *external) Delete(ctx context.Context, cr *v1alpha1.K8sClusterConnector) (managed.ExternalDelete, error) {
	client := c.service.(*clients.Client)
	orgID := ""
	if cr.Spec.ForProvider.OrgId != nil {
		orgID = *cr.Spec.ForProvider.OrgId
	}
	projectID := ""
	if cr.Spec.ForProvider.ProjectId != nil {
		projectID = *cr.Spec.ForProvider.ProjectId
	}

	err := client.DeleteConnector(ctx, orgID, projectID, cr.Status.AtProvider.ID)
	if err != nil {
		return managed.ExternalDelete{}, err
	}

	return managed.ExternalDelete{}, nil
}

func (c *external) Disconnect(ctx context.Context) error {
	return nil
}
