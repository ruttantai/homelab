# Managed by Ansible (roles/lmod). Spack writes Tcl modulefiles; Lmod reads them (spec §10.10).
if ! type module >/dev/null 2>&1 && [ -f /usr/share/lmod/lmod/init/bash ]; then
  . /usr/share/lmod/lmod/init/bash
fi
for d in /opt/spack/share/spack/modules/*; do
  [ -d "$d" ] && module use "$d"
done
