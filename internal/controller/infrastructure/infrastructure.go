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

package infrastructure

import (
	"context"
	"fmt"

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

	v1alpha1 "github.com/jeremywyx/provider-harness/apis/infrastructure/v1alpha1"
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

// SetupGated adds a controller that reconciles Infrastructure managed resources with safe-start support.
func SetupGated(mgr ctrl.Manager, o controller.Options) error {
	o.Gate.Register(func() {
		if err := Setup(mgr, o); err != nil {
			panic(errors.Wrap(err, "cannot setup Infrastructure controller"))
		}
	}, v1alpha1.InfrastructureGroupVersionKind)
	return nil
}

// Setup adds a controller that reconciles Infrastructure managed resources.
func Setup(mgr ctrl.Manager, o controller.Options) error {
	name := managed.ControllerName(v1alpha1.InfrastructureGroupKind)

	opts := []managed.ReconcilerOption{
		managed.WithTypedExternalConnector[*v1alpha1.Infrastructure](&connector{
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
			mgr.GetClient(), o.Logger, o.MetricOptions.MRStateMetrics, &v1alpha1.InfrastructureList{}, o.MetricOptions.PollStateMetricInterval,
		)
		if err := mgr.Add(stateMetricsRecorder); err != nil {
			return errors.Wrap(err, "cannot register MR state metrics recorder for kind v1alpha1.InfrastructureList")
		}
	}

	r := managed.NewReconciler(mgr, resource.ManagedKind(v1alpha1.InfrastructureGroupVersionKind), opts...)

	return ctrl.NewControllerManagedBy(mgr).
		Named(name).
		WithOptions(o.ForControllerRuntime()).
		WithEventFilter(resource.DesiredStateChanged()).
		For(&v1alpha1.Infrastructure{}).
		Complete(ratelimiter.NewReconciler(name, r, o.GlobalRateLimiter))
}

type connector struct {
	kube         client.Client
	usage        *resource.ProviderConfigUsageTracker
	newServiceFn func(creds []byte, accountID string, endpoint string) (interface{}, error)
}

func (c *connector) Connect(ctx context.Context, cr *v1alpha1.Infrastructure) (managed.TypedExternalClient[*v1alpha1.Infrastructure], error) {
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

func generateInfrastructurePayload(cr *v1alpha1.Infrastructure) *clients.InfrastructureData {
	orgID := ""
	if cr.Spec.ForProvider.OrgId != nil {
		orgID = *cr.Spec.ForProvider.OrgId
	}
	projectID := ""
	if cr.Spec.ForProvider.ProjectId != nil {
		projectID = *cr.Spec.ForProvider.ProjectId
	}

	identifier := meta.GetExternalName(cr)
	if identifier == "" {
		identifier = cr.GetName()
	}

	yamlTemplate := `infrastructureDefinition:
  name: %s
  identifier: %s
  description: ""
  orgIdentifier: %s
  projectIdentifier: %s
  environmentRef: %s
  deploymentType: %s
  type: %s
  spec:
    connectorRef: %s
    namespace: %s
    releaseName: release-%s`

	yamlStr := fmt.Sprintf(yamlTemplate,
		cr.GetName(),
		identifier,
		orgID,
		projectID,
		cr.Spec.ForProvider.EnvId,
		cr.Spec.ForProvider.DeploymentType,
		cr.Spec.ForProvider.Type,
		cr.Spec.ForProvider.ConnectorRef,
		cr.Spec.ForProvider.Namespace,
		identifier,
	)

	return &clients.InfrastructureData{
		Name:              cr.GetName(),
		Identifier:        identifier,
		OrgIdentifier:     orgID,
		ProjectIdentifier: projectID,
		EnvironmentRef:    cr.Spec.ForProvider.EnvId,
		Type:              cr.Spec.ForProvider.Type,
		DeploymentType:    cr.Spec.ForProvider.DeploymentType,
		Yaml:              yamlStr,
	}
}

func (c *external) Observe(ctx context.Context, cr *v1alpha1.Infrastructure) (managed.ExternalObservation, error) {
	client := c.service.(*clients.Client)
	infraName := meta.GetExternalName(cr)
	if infraName == "" {
		infraName = cr.GetName()
	}

	orgID := ""
	if cr.Spec.ForProvider.OrgId != nil {
		orgID = *cr.Spec.ForProvider.OrgId
	}
	projectID := ""
	if cr.Spec.ForProvider.ProjectId != nil {
		projectID = *cr.Spec.ForProvider.ProjectId
	}

	infra, err := client.GetInfrastructure(ctx, orgID, projectID, cr.Spec.ForProvider.EnvId, infraName)
	if err != nil {
		return managed.ExternalObservation{}, err
	}

	if infra == nil {
		return managed.ExternalObservation{
			ResourceExists: false,
		}, nil
	}

	meta.SetExternalName(cr, infra.Identifier)
	cr.Status.AtProvider.ID = infra.Identifier
	cr.SetConditions(xpv2.Available())

	upToDate := true

	return managed.ExternalObservation{
		ResourceExists:    true,
		ResourceUpToDate:  upToDate,
		ConnectionDetails: managed.ConnectionDetails{},
	}, nil
}

func (c *external) Create(ctx context.Context, cr *v1alpha1.Infrastructure) (managed.ExternalCreation, error) {
	client := c.service.(*clients.Client)
	orgID := ""
	if cr.Spec.ForProvider.OrgId != nil {
		orgID = *cr.Spec.ForProvider.OrgId
	}
	projectID := ""
	if cr.Spec.ForProvider.ProjectId != nil {
		projectID = *cr.Spec.ForProvider.ProjectId
	}

	payload := generateInfrastructurePayload(cr)
	infra, err := client.CreateInfrastructure(ctx, orgID, projectID, payload)
	if err != nil {
		return managed.ExternalCreation{}, err
	}

	meta.SetExternalName(cr, infra.Identifier)
	cr.Status.AtProvider.ID = infra.Identifier

	return managed.ExternalCreation{}, nil
}

func (c *external) Update(ctx context.Context, cr *v1alpha1.Infrastructure) (managed.ExternalUpdate, error) {
	client := c.service.(*clients.Client)
	orgID := ""
	if cr.Spec.ForProvider.OrgId != nil {
		orgID = *cr.Spec.ForProvider.OrgId
	}
	projectID := ""
	if cr.Spec.ForProvider.ProjectId != nil {
		projectID = *cr.Spec.ForProvider.ProjectId
	}

	payload := generateInfrastructurePayload(cr)
	_, err := client.UpdateInfrastructure(ctx, orgID, projectID, payload)
	if err != nil {
		return managed.ExternalUpdate{}, err
	}

	return managed.ExternalUpdate{}, nil
}

func (c *external) Delete(ctx context.Context, cr *v1alpha1.Infrastructure) (managed.ExternalDelete, error) {
	client := c.service.(*clients.Client)
	orgID := ""
	if cr.Spec.ForProvider.OrgId != nil {
		orgID = *cr.Spec.ForProvider.OrgId
	}
	projectID := ""
	if cr.Spec.ForProvider.ProjectId != nil {
		projectID = *cr.Spec.ForProvider.ProjectId
	}

	err := client.DeleteInfrastructure(ctx, orgID, projectID, cr.Spec.ForProvider.EnvId, cr.Status.AtProvider.ID)
	if err != nil {
		return managed.ExternalDelete{}, err
	}

	return managed.ExternalDelete{}, nil
}

func (c *external) Disconnect(ctx context.Context) error {
	return nil
}
