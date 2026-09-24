package SortedTreeStore;

###############################################################################
# This file is part of Ásbrú Connection Manager
#
# Copyright (C) 2017-2022 Ásbrú Connection Manager team (https://asbru-cm.net)
#
# Ásbrú Connection Manager is free software: you can redistribute it and/or
# modify it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Ásbrú Connection Manager is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License version 3
# along with Ásbrú Connection Manager.
# If not, see <http://www.gnu.org/licenses/gpl-3.0.html>.
###############################################################################

use utf8;
binmode STDOUT,':utf8';
binmode STDERR,':utf8';

$|++;

###################################################################
# Import Modules

# Standard
use strict;
use warnings;

# GTK
use Gtk3 '-init';

# END: Import Modules
###################################################################

use Glib::Object::Subclass
    'Gtk3::TreeModelSort',
    interfaces => [ 'Gtk3::TreeDragSource', 'Gtk3::TreeDragDest' ];

###################################################################
# START: Public class methods
sub create {
    my ($class, $model, $cfg, $verbose) = @_;

    my $self = $class->new(model => $model);

    $$self{_CFG} = $cfg;
    $$self{_VERBOSE} = $verbose;

    $self->set_default_sort_func(\&__treeSort, $self);

    bless($self, $class);
    return $self;
}
# END: Public class methods
###################################################################

###################################################################
# START: Interface overrides

# Asks if the row specified by path can be used as the source of a DND operation.
# (Returns true if the row can be dragged)
sub ROW_DRAGGABLE {
    my ($self, $dest_path) = @_;
    my ($uuid, $dest, $iter);

    $iter = $self->get_iter($dest_path);

    if ($iter) {
        $uuid = $self->get_value($iter, 2);

        # The root node cannot be dragged
        if ($uuid eq '__PAC__ROOT__') {
            return 0;
        }
    }

    # All other nodes are draggable
    return 1;
}

# Asks to fill in the selection data object specified by selection_data with a representation of the row specified by path.
# The selection_data target attribute gives the required type of the data.
# (Returns true if data of the required type was provided)
sub DRAG_DATA_GET {
    my ($self, $dest_path, $selection_data) = @_;

    return 0;
}

# Asks to delete the row specified by path, because it was moved somewhere else via drag-and-drop.
# This method returns false if the deletion fails because path no longer exists, or for some other model-specific reason.
sub DRAG_DATA_DELETE {
    my ($self, $dest_path) = @_;

    # Move and deletion are managed elsewhere in Ásbrú (in PACMain)
    return 0;
}


# Asks to insert a row before the path dest, deriving the contents of the row from selection_data. If dest is outside the tree
# so that inserting before it is impossible, false will be returned.
# Also, false may be returned if the new row is not created for some model-specific reason.
# (Returns true if a new row was created before position dest)
sub DRAG_DATA_RECEIVED {
    my ($self, $dest_path, $selection_data) = @_;

    # Move and deletion are managed elsewhere in Ásbrú (in PACMain)
    return 0;
}

# Determines if a drop is possible before the tree path specified by dest_path and at the same depth as dest_path.
# That is, can we drop the data specified by selection_data at that location.
# (Returns true if a drop is possible before dest_path)
sub ROW_DROP_POSSIBLE {
    my ($self, $dest_path, $selection_data) = @_;
    my ($uuid, $dest, $iter);

    $iter = $self->get_iter($dest_path);

    if ($iter) {
        $uuid = $self->get_value($iter, 2);

        if ($uuid eq '__PAC__ROOT__') {
            return 1;
        }

        $dest = $$self{_CFG}{'environments'}{$uuid};
    }

    if ($iter && $dest) {
        if (!$$self{_CFG}{'environments'}{$uuid}{'_is_group'}) {
            return 0;
        }
    }

    if ($iter && $dest) {
        if ($$self{_VERBOSE}) {
            print("Drop possible for UUID=[$uuid], Name=[$$dest{'name'}], Is Group?=[$$dest{'_is_group'}]\n");
        }

        return $$dest{'_is_group'} && !$$dest{'_protected'};
    }

    return 0;
}
# END: Interface overrides
###################################################################

###################################################################
# START: Private functions definitions
sub __treeSort {
    my ($treestore, $a_iter, $b_iter, $self) = @_;
    my $cfg = $$self{_CFG};

    my $a_uuid = $treestore->get_value($a_iter, 2);
    my $b_uuid = $treestore->get_value($b_iter, 2);

    return 1 if (!defined $a_uuid);
    return -1 if (!defined $b_uuid);

    # __PAC__ROOT__ must always be the first node!!
    return -1 if ($a_uuid eq '__PAC__ROOT__');
    return 1 if ($b_uuid eq '__PAC__ROOT__');

    my $a_node = $$cfg{'environments'}{$a_uuid};
    my $b_node = $$cfg{'environments'}{$b_uuid};

    # Groups first...
    my $groups_1st = ($$self{_groups_1st} //= ($$cfg{'defaults'}{'sort groups first'} // 1));
    if ($groups_1st) {
        my $a_is_group = (ref($a_node) eq 'HASH') ? ($$a_node{'_is_group'} // 0) : 0;
        my $b_is_group = (ref($b_node) eq 'HASH') ? ($$b_node{'_is_group'} // 0) : 0;
        if ($a_is_group && !$b_is_group) {
            return -1;
        }
        if (!$a_is_group && $b_is_group) {
            return 1;
        }
    }

    # Compare names using memoized lowercase strings to eliminate tens of thousands of lc() calls during sort
    my $a_name_lc;
    if (ref($a_node) eq 'HASH') {
        $a_name_lc = ($$a_node{'_name_lc'} //= lc($$a_node{'name'} // ''));
    }
    if (!defined $a_name_lc || $a_name_lc eq '') {
        my $val = $treestore->get_value($a_iter, 1) // '';
        $val =~ s/<.*?> ?//g if ($val =~ /</);
        $a_name_lc = lc($val);
    }

    my $b_name_lc;
    if (ref($b_node) eq 'HASH') {
        $b_name_lc = ($$b_node{'_name_lc'} //= lc($$b_node{'name'} // ''));
    }
    if (!defined $b_name_lc || $b_name_lc eq '') {
        my $val = $treestore->get_value($b_iter, 1) // '';
        $val =~ s/<.*?> ?//g if ($val =~ /</);
        $b_name_lc = lc($val);
    }

    # ... then alphabetically
    return $a_name_lc cmp $b_name_lc;
}
# END: Private functions definitions
###################################################################

1;

__END__

=encoding utf8

=head1 NAME

SortedTreeStore.pm

=head1 SYNOPSIS

Overrides the standard Gtk3::TreeModelSort to properly implement the drag and drop interfaces
Gtk3::TreeDragSource and Gtk3::TreeDragDest.
