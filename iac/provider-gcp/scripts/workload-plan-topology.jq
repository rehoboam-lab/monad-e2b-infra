def managed_changes:
  [
    .resource_changes[]?
    | select(.mode == "managed")
  ];

def is_mig:
  .type == "google_compute_instance_group_manager"
  or .type == "google_compute_region_instance_group_manager";

def mig_role:
  if .type == "google_compute_region_instance_group_manager"
    and (.address == "module.cluster.google_compute_region_instance_group_manager.server_pool") then
    "server"
  elif .type == "google_compute_instance_group_manager"
    and (.address == "module.cluster.google_compute_instance_group_manager.api_pool") then
    "api"
  elif .type == "google_compute_instance_group_manager"
    and (.address == "module.cluster.google_compute_instance_group_manager.clickhouse_pool") then
    "clickhouse"
  elif .type == "google_compute_instance_group_manager"
    and (.address == "module.cluster.google_compute_instance_group_manager.loki_pool") then
    "loki"
  elif .type == "google_compute_region_instance_group_manager"
    and (
      .address
      | test(
          "^module\\.cluster\\.module\\.build_cluster\\[\"[^\"]+\"\\]\\.google_compute_region_instance_group_manager\\.pool$"
        )
    ) then
    "build"
  elif .type == "google_compute_region_instance_group_manager"
    and (
      .address
      | test(
          "^module\\.cluster\\.module\\.client_cluster\\[\"[^\"]+\"\\]\\.google_compute_region_instance_group_manager\\.pool$"
        )
    ) then
    "client"
  else
    null
  end;

def template_role:
  if .type != "google_compute_instance_template" then
    null
  elif .address == "module.cluster.google_compute_instance_template.server" then
    "server"
  elif .address == "module.cluster.google_compute_instance_template.api" then
    "api"
  elif .address == "module.cluster.google_compute_instance_template.clickhouse" then
    "clickhouse"
  elif .address == "module.cluster.google_compute_instance_template.loki" then
    "loki"
  elif (
    .address
    | test(
        "^module\\.cluster\\.module\\.build_cluster\\[\"[^\"]+\"\\]\\.google_compute_instance_template\\.template$"
      )
  ) then
    "build"
  elif (
    .address
    | test(
        "^module\\.cluster\\.module\\.client_cluster\\[\"[^\"]+\"\\]\\.google_compute_instance_template\\.template$"
      )
  ) then
    "client"
  else
    null
  end;

def autoscaler_address($address):
  $address
  | sub(
      "\\.google_compute_region_instance_group_manager\\.pool$";
      ".google_compute_region_autoscaler.autoscaler[0]"
    );

def unknown_field($resource; $field):
  any(
    ($resource.change.after_unknown // {} | .. | objects);
    has($field) and .[$field] == true
  );

def unknown_child_field($resource; $container; $field):
  any(
    (
      $resource.change.after_unknown[$container]
      // []
      | ..
      | objects
    );
    has($field) and .[$field] == true
  );

def capacity($resource; $changes):
  if unknown_field($resource; "target_size") then
    null
  elif ($resource.change.after.target_size | type) == "number" then
    $resource.change.after.target_size
  else
    autoscaler_address($resource.address) as $autoscaler_address
    | (
        [
          $changes[]
          | select(.address == $autoscaler_address)
          | select((.change.after_unknown.autoscaling_policy // false) != true)
          | select(unknown_field(.; "max_replicas") | not)
          | .change.after.autoscaling_policy[0].max_replicas
        ][0] // null
      )
  end;

def previous_capacity($resource; $changes):
  if ($resource.change.before.target_size | type) == "number" then
    $resource.change.before.target_size
  else
    autoscaler_address($resource.address) as $autoscaler_address
    | (
        [
          $changes[]
          | select(.address == $autoscaler_address)
          | .change.before.autoscaling_policy[0].max_replicas
          | select(type == "number")
        ][0] // null
      )
  end;

def machine_vcpus($machine_type):
  try (
    $machine_type
    | capture("^(?:e2|n1)-standard-(?<vcpus>[1-9][0-9]*)$")
    | .vcpus
    | tonumber
  ) catch null;

def disk_usage($resource):
  reduce ($resource.change.after.disk // [])[] as $disk (
    {
      pd_ssd_gb: 0,
      pd_standard_gb: 0,
      local_ssd_gb: 0,
      invalid: []
    };
    if (
      ($disk.disk_size_gb | type) != "number"
      or $disk.disk_size_gb <= 0
      or ($disk.disk_size_gb | floor) != $disk.disk_size_gb
    ) then
      .invalid += [
        {
          disk_type: ($disk.disk_type // null),
          disk_size_gb: ($disk.disk_size_gb // null),
          reason: "invalid-size"
        }
      ]
    elif (
      ($disk.disk_type == "pd-ssd" or $disk.disk_type == "pd-balanced")
      and (($disk.type // "PERSISTENT") == "PERSISTENT")
    ) then
      .pd_ssd_gb += $disk.disk_size_gb
    elif (
      $disk.disk_type == "pd-standard"
      and (($disk.type // "PERSISTENT") == "PERSISTENT")
    ) then
      .pd_standard_gb += $disk.disk_size_gb
    elif $disk.disk_type == "local-ssd" and $disk.type == "SCRATCH" then
      .local_ssd_gb += $disk.disk_size_gb
    else
      .invalid += [
        {
          disk_type: ($disk.disk_type // null),
          disk_size_gb: $disk.disk_size_gb,
          disk_resource_type: ($disk.type // null),
          reason: "unsupported-type"
        }
      ]
    end
  );

def number_or_zero($value):
  if ($value | type) == "number" then $value else 0 end;

def usage_zero:
  {
    instances: 0,
    global_vcpus: 0,
    pd_ssd_gb: 0,
    pd_standard_gb: 0,
    local_ssd_gb: 0,
    regional_public_ips: 0
  };

def add_usage($left; $right):
  reduce (usage_zero | keys[]) as $key (
    {};
    .[$key] = (
      number_or_zero($left[$key])
      + number_or_zero($right[$key])
    )
  );

def max_usage($left; $right):
  reduce (usage_zero | keys[]) as $key (
    {};
    .[$key] = (
      [
        number_or_zero($left[$key]),
        number_or_zero($right[$key])
      ]
      | max
    )
  );

def role_template($templates; $role):
  (
    [
      $templates[]
      | select(.role == $role)
    ][0]
    // {
      vcpus: 0,
      pd_ssd_gb: 0,
      pd_standard_gb: 0,
      local_ssd_gb: 0,
      regional_public_ip: false
    }
  );

def scaled_role_usage($templates; $role; $count):
  role_template($templates; $role) as $template
  | {
      instances: number_or_zero($count),
      global_vcpus: (
        number_or_zero($template.vcpus)
        * number_or_zero($count)
      ),
      pd_ssd_gb: (
        number_or_zero($template.pd_ssd_gb)
        * number_or_zero($count)
      ),
      pd_standard_gb: (
        number_or_zero($template.pd_standard_gb)
        * number_or_zero($count)
      ),
      local_ssd_gb: (
        number_or_zero($template.local_ssd_gb)
        * number_or_zero($count)
      ),
      regional_public_ips: (
        if $template.regional_public_ip == true then
          number_or_zero($count)
        else
          0
        end
      )
    };

def reserve_usage($reserve):
  {
    instances: $reserve.instances,
    global_vcpus: $reserve.vcpus,
    pd_ssd_gb: $reserve.pd_ssd_gb,
    pd_standard_gb: $reserve.pd_standard_gb,
    local_ssd_gb: $reserve.local_ssd_gb,
    regional_public_ips: $reserve.regional_public_ips
  };

managed_changes as $changes
| (
    [
      $changes[]
      | select(is_mig)
    ]
  ) as $migs
| (
    [
      $changes[]
      | select(.type == "google_compute_instance_template")
    ]
  ) as $instance_templates
| (
    [
      $instance_templates[] as $resource
      | ($resource | template_role) as $role
      | select($role != null)
      | disk_usage($resource) as $disk_usage
      | ($resource.change.after.network_interface // []) as $network_interfaces
      | {
          address: $resource.address,
          role: $role,
          machine_type: ($resource.change.after.machine_type // null),
          vcpus: machine_vcpus($resource.change.after.machine_type),
          pd_ssd_gb: $disk_usage.pd_ssd_gb,
          pd_standard_gb: $disk_usage.pd_standard_gb,
          local_ssd_gb: $disk_usage.local_ssd_gb,
          regional_public_ip: (
            if (
              ($network_interfaces | length) == 1
              and ($network_interfaces[0].access_config | type) == "array"
            ) then
              ($network_interfaces[0].access_config | length) == 1
            else
              null
            end
          ),
          invalid_disks: $disk_usage.invalid,
          unresolved: (
            unknown_field($resource; "machine_type")
            or machine_vcpus($resource.change.after.machine_type) == null
            or unknown_field($resource; "disk")
            or unknown_child_field($resource; "disk"; "disk_size_gb")
            or unknown_child_field($resource; "disk"; "disk_type")
            or unknown_child_field($resource; "disk"; "type")
            or unknown_field($resource; "network_interface")
            or unknown_child_field(
              $resource;
              "network_interface";
              "access_config"
            )
            or (($resource.change.after.disk // []) | length) == 0
            or ($network_interfaces | length) != 1
            or ($network_interfaces[0].access_config | type) != "array"
            or ($network_interfaces[0].access_config | length) > 1
          )
        }
    ]
  ) as $templates
| (
    [
      $migs[] as $resource
      | ($resource | mig_role) as $role
      | select($role != null)
      | capacity($resource; $changes) as $capacity
      | {
          address: $resource.address,
          role: $role,
          actions: $resource.change.actions,
          capacity: $capacity,
          previous_capacity: previous_capacity($resource; $changes),
          surge: (
            if $capacity == 0 then
              0
            else
              ($resource.change.after.update_policy[0].max_surge_fixed // 0)
            end
          ),
          surge_percent: (
            if $capacity == 0 then
              0
            else
              ($resource.change.after.update_policy[0].max_surge_percent // 0)
            end
          ),
          max_unavailable: (
            if $capacity == 0 then
              0
            else
              (
                $resource.change.after.update_policy[0].max_unavailable_fixed
                // 0
              )
            end
          ),
          surge_unknown: (
            ($resource.change.after_unknown.update_policy // false) == true
            or unknown_field($resource; "max_surge_fixed")
            or unknown_field($resource; "max_surge_percent")
          ),
          max_unavailable_unknown: (
            ($resource.change.after_unknown.update_policy // false) == true
            or unknown_field($resource; "max_unavailable_fixed")
          )
        }
    ]
  ) as $rows
| (
    reduce ($expected.expected_role_max_instances | keys[]) as $role (
      {};
      .[$role] = (
        [
          $rows[]
          | select(.role == $role)
          | .capacity
          | select(type == "number")
        ]
        | add // 0
      )
    )
  ) as $role_max_instances
| (
    reduce ($expected.expected_role_surge_instances | keys[]) as $role (
      {};
      .[$role] = (
        [
          $rows[]
          | select(.role == $role)
          | .surge
          | select(type == "number")
        ]
        | add // 0
      )
    )
  ) as $role_surge_instances
| (
    reduce (
      $expected.expected_role_max_unavailable_instances
      | keys[]
    ) as $role (
      {};
      .[$role] = (
        [
          $rows[]
          | select(.role == $role)
          | .max_unavailable
          | select(type == "number")
        ]
        | add // 0
      )
    )
  ) as $role_max_unavailable_instances
| (
    reduce ($expected.expected_role_resources | keys[]) as $role (
      {};
      .[$role] = (
        [
          $templates[]
          | select(.role == $role)
          | {
              machine_type,
              vcpus,
              pd_ssd_gb,
              pd_standard_gb,
              local_ssd_gb,
              regional_public_ip
            }
        ][0] // null
      )
    )
  ) as $role_resources
| (
    reduce $rows[] as $row (
      usage_zero;
      add_usage(
        .;
        scaled_role_usage(
          $templates;
          $row.role;
          number_or_zero($row.capacity)
        )
      )
    )
  ) as $base_usage
| (
    reduce $rows[] as $row (
      usage_zero;
      add_usage(
        .;
        scaled_role_usage(
          $templates;
          $row.role;
          number_or_zero($row.surge)
        )
      )
    )
  ) as $surge_usage
| add_usage($base_usage; $surge_usage) as $rollout_usage
| add_usage(
    $base_usage;
    reserve_usage($expected.transient_reserve)
  ) as $packer_usage
| max_usage($rollout_usage; $packer_usage) as $peak_usage
| {
    role_max_instances: $role_max_instances,
    role_surge_instances: $role_surge_instances,
    role_max_unavailable_instances: $role_max_unavailable_instances,
    role_resources: $role_resources,
    base_usage: $base_usage,
    rollout_usage: $rollout_usage,
    packer_usage: $packer_usage,
    peak_usage: $peak_usage,
    destructive_migs: [
      $migs[]
      | select(.change.actions | index("delete"))
      | .address
    ],
    unknown_migs: [
      $migs[]
      | select(mig_role == null)
      | .address
    ],
    unknown_templates: [
      $instance_templates[]
      | select(template_role == null)
      | .address
    ],
    unexpected_quota_resources: [
      $changes[]
      | select(
          .type == "google_compute_instance"
          or .type == "google_compute_disk"
          or .type == "google_compute_region_disk"
          or .type == "google_compute_address"
          or .type == "google_compute_region_address"
          or .type == "google_compute_region_autoscaler"
        )
      | {
          address,
          type
        }
    ],
    missing_or_duplicate_mig_roles: [
      $expected.expected_role_max_instances
      | keys[] as $role
      | (
          [
            $rows[]
            | select(.role == $role)
          ]
          | length
        ) as $count
      | select($count != 1)
      | {
          role: $role,
          count: $count
        }
    ],
    missing_or_duplicate_template_roles: [
      $expected.expected_role_resources
      | keys[] as $role
      | (
          [
            $templates[]
            | select(.role == $role)
          ]
          | length
        ) as $count
      | select($count != 1)
      | {
          role: $role,
          count: $count
        }
    ],
    unresolved_capacities: [
      $rows[]
      | select((.capacity | type) != "number")
      | .address
    ],
    unresolved_previous_capacities: [
      $rows[]
      | select(.actions | index("create") | not)
      | select((.previous_capacity | type) != "number")
      | .address
    ],
    capacity_reductions: [
      $rows[]
      | select((.previous_capacity | type) == "number")
      | select((.capacity | type) == "number")
      | select(.capacity < .previous_capacity)
      | {
          address,
          before: .previous_capacity,
          after: .capacity
        }
    ],
    unresolved_surges: [
      $rows[]
      | select(.capacity != 0 and .surge_unknown)
      | .address
    ],
    unresolved_max_unavailable: [
      $rows[]
      | select(.capacity != 0 and .max_unavailable_unknown)
      | .address
    ],
    invalid_surges: [
      $rows[]
      | select(
          (.surge | type) != "number"
          or .surge < 0
          or (.surge | floor) != .surge
        )
      | {
          address,
          surge
        }
    ],
    percentage_surges: [
      $rows[]
      | select(.surge_percent != 0)
      | .address
    ],
    invalid_max_unavailable: [
      $rows[]
      | select(
          (.max_unavailable | type) != "number"
          or .max_unavailable < 0
          or (.max_unavailable | floor) != .max_unavailable
        )
      | {
          address,
          max_unavailable
        }
    ],
    automated_worker_server_surges: [
      $rows[]
      | select(
          .role == "build"
          or .role == "client"
          or .role == "server"
        )
      | select(
          (.surge | type) != "number"
          or (
            .surge
            > $expected.max_automated_worker_server_surge_per_pool
          )
        )
      | {
          address,
          role,
          surge
        }
    ],
    unresolved_templates: [
      $templates[]
      | select(.unresolved)
      | .address
    ],
    invalid_template_disks: [
      $templates[]
      | select((.invalid_disks | length) != 0)
      | {
          address,
          disks: .invalid_disks
        }
    ],
    quota_violations: [
      $expected.quota_limits
      | keys[] as $quota
      | select($peak_usage[$quota] > $expected.quota_limits[$quota])
      | {
          quota: $quota,
          planned: $peak_usage[$quota],
          limit: $expected.quota_limits[$quota]
        }
    ]
  }
