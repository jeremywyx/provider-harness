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

package delegate

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

	v1alpha1 "github.com/jeremywyx/provider-harness/apis/delegate/v1alpha1"
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

// SetupGated adds a controller that reconciles Delegate managed resources with safe-start support.
func SetupGated(mgr ctrl.Manager, o controller.Options) error {
	o.Gate.Register(func() {
		if err := Setup(mgr, o); err != nil {
			panic(errors.Wrap(err, "cannot setup Delegate controller"))
		}
	}, v1alpha1.DelegateGroupVersionKind)
	return nil
}

// Setup adds a controller that reconciles Delegate managed resources.
func Setup(mgr ctrl.Manager, o controller.Options) error {
	name := managed.ControllerName(v1alpha1.DelegateGroupKind)

	opts := []managed.ReconcilerOption{
		managed.WithTypedExternalConnector[*v1alpha1.Delegate](&connector{
			kube:         mgr.GetClient(),
			usage:        resource.NewProviderConfigUsageTracker(mgr.GetClient(), &apisv1alpha1.ProviderConfigUsage{}),
			newServiceFn: newHarnessClient}),
		managed.WithLogger(o.Logger.WithValues("controller", name)),
		managed.WithPollInterval(o.PollInterval),
		managed.WithRecorder(event.NewAPIRecorder(mgr.GetEventRecorderFor(name))), //nolint:staticcheck // TODO(jbw976) Crossplane needs to update to the new events API, see https://github.com/crossplane/crossplane/issues/7152
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
			mgr.GetClient(), o.Logger, o.MetricOptions.MRStateMetrics, &v1alpha1.DelegateList{}, o.MetricOptions.PollStateMetricInterval,
		)
		if err := mgr.Add(stateMetricsRecorder); err != nil {
			return errors.Wrap(err, "cannot register MR state metrics recorder for kind v1alpha1.DelegateList")
		}
	}

	r := managed.NewReconciler(mgr, resource.ManagedKind(v1alpha1.DelegateGroupVersionKind), opts...)

	return ctrl.NewControllerManagedBy(mgr).
		Named(name).
		WithOptions(o.ForControllerRuntime()).
		WithEventFilter(resource.DesiredStateChanged()).
		For(&v1alpha1.Delegate{}).
		Complete(ratelimiter.NewReconciler(name, r, o.GlobalRateLimiter))
}

// A connector is expected to produce an ExternalClient when its Connect method
// is called.
type connector struct {
	kube         client.Client
	usage        *resource.ProviderConfigUsageTracker
	newServiceFn func(creds []byte, accountID string, endpoint string) (interface{}, error)
}

// Connect produces an ExternalClient using credentials from the referenced ProviderConfig.
func (c *connector) Connect(ctx context.Context, cr *v1alpha1.Delegate) (managed.TypedExternalClient[*v1alpha1.Delegate], error) {
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

// An ExternalClient observes, then either creates, updates, or deletes an
// external resource to ensure it reflects the managed resource's desired state.
type external struct {
	service interface{}
}

func (c *external) Observe(ctx context.Context, cr *v1alpha1.Delegate) (managed.ExternalObservation, error) {
	client := c.service.(*clients.Client)
	identifier := cr.Spec.ForProvider.DelegateIdentifier
	orgID := ""
	if cr.Spec.ForProvider.OrgId != nil {
		orgID = *cr.Spec.ForProvider.OrgId
	}
	projectID := ""
	if cr.Spec.ForProvider.ProjectId != nil {
		projectID = *cr.Spec.ForProvider.ProjectId
	}

	del, err := client.GetDelegate(ctx, orgID, projectID, identifier)
	if err != nil {
		return managed.ExternalObservation{}, err
	}

	if del == nil {
		return managed.ExternalObservation{
			ResourceExists: false,
		}, nil
	}

	cr.Status.AtProvider.ID = del.ID
	cr.Status.AtProvider.Hostname = del.Hostname
	cr.Status.AtProvider.Status = del.Status
	cr.Status.AtProvider.Version = del.Version
	cr.Status.AtProvider.DelegateType = del.DelegateType

	meta.SetExternalName(cr, del.Name)

	if del.Status == "ENABLED" {
		cr.SetConditions(xpv2.Available())
	} else {
		cr.SetConditions(xpv2.Unavailable())
	}

	return managed.ExternalObservation{
		ResourceExists:    true,
		ResourceUpToDate:  true,
		ConnectionDetails: managed.ConnectionDetails{},
	}, nil
}

func (c *external) Create(ctx context.Context, cr *v1alpha1.Delegate) (managed.ExternalCreation, error) {
	// A delegate is onboarded externally by deploying the agent into the infrastructure
	// (e.g. via Helm or ArgoCD). The Crossplane resource simply tracks its registration status.
	return managed.ExternalCreation{}, nil
}

func (c *external) Update(ctx context.Context, cr *v1alpha1.Delegate) (managed.ExternalUpdate, error) {
	return managed.ExternalUpdate{}, nil
}

func (c *external) Delete(ctx context.Context, cr *v1alpha1.Delegate) (managed.ExternalDelete, error) {
	client := c.service.(*clients.Client)
	orgID := ""
	if cr.Spec.ForProvider.OrgId != nil {
		orgID = *cr.Spec.ForProvider.OrgId
	}
	projectID := ""
	if cr.Spec.ForProvider.ProjectId != nil {
		projectID = *cr.Spec.ForProvider.ProjectId
	}

	err := client.DeleteDelegate(ctx, orgID, projectID, cr.Spec.ForProvider.DelegateIdentifier)
	if err != nil {
		return managed.ExternalDelete{}, err
	}

	return managed.ExternalDelete{}, nil
}

func (c *external) Disconnect(ctx context.Context) error {
	return nil
}
