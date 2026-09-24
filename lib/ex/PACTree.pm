package PACTree;

###############################################################################
# This file is part of Ásbrú Connection Manager
#
# Copyright (C) 2017-2026 Ásbrú Connection Manager team (https://asbru-cm.net)
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

use strict;
use Carp;
use Gtk3;

use PACUtils;

use TiedTree;

use base 'Gtk3::TreeView';

our %column_types;
*column_types = \%Gtk3::SimpleList::column_types;
*add_column_type = \&Gtk3::SimpleList::add_column_type;

# Start Ásbrú specific methods
sub _getSelectedUUIDs {
    my $self = shift;
    my $selection = $self->get_selection();
    my $model = $self->get_model();
    my @paths = _getSelectedRows($selection);

    my @selected;

    scalar(@paths) or push(@selected, '__PAC__ROOT__');
    foreach my $path (@paths) {
        push(@selected, $model->get_value($model->get_iter($path), 2));
    }

    return wantarray ? @selected : scalar(@selected);
}

sub _getSelectedNames {
    my $self = shift;
    my $selection = $self->get_selection();
    my $model = $self->get_model();
    my @paths = _getSelectedRows($selection);

    my @selected;

    foreach my $path (@paths) {
        push(@selected, $model->get_value($model->get_iter($path), 1));
    }

    return wantarray ? @selected : scalar(@selected);
}

sub _getSelectedTerminals {
    my $self = shift;
    my $selection = $self->get_selection();
    my $model = $self->get_model();
    my @paths = _getSelectedRows($selection);
    my @selected;

    foreach my $path (@paths) {
        my $name = $model->get_value($model->get_iter($path), 1);
        my $uuid = $model->get_value($model->get_iter($path), 2);
        $name =~s /<.+?> *//g;

        push(@selected, {
            'name' => $name,
            'uuid' => $uuid
        });
    }

    return @selected;
}

sub _getChildren {
    my $self = shift;
    my $uuid = shift;
    my $which = shift // 'all'; # 0:nodes, 1:groups, all:nodes+groups
    my $deep = shift // 0;      # 0:1st_level, 1:all_levels
    my $hash = shift // 0;

    # Try ultra-fast in-memory lookup first if config environments is available
    my $cfg = $PACMain::FUNCS{_MAIN}{_CFG};
    if ($cfg && $cfg->{environments} && defined $uuid && exists $cfg->{environments}{$uuid}) {
        my @list;
        my $collect;
        $collect = sub {
            my $parent = shift;
            my $children = $cfg->{environments}{$parent}{children};
            return unless $children && ref($children) eq 'HASH';
            foreach my $child_uuid (sort keys %$children) {
                my $cnode = $cfg->{environments}{$child_uuid};
                next unless $cnode;
                my $is_grp = $cnode->{_is_group} // 0;
                my $matches = ($which eq 'all') || ($which == 1 && $is_grp) || ($which == 0 && !$is_grp);
                if ($matches && $child_uuid ne '__PAC__ROOT__') {
                    if ($hash) {
                        push @list, { name => ($cnode->{name} // ''), uuid => $child_uuid };
                    } else {
                        push @list, $child_uuid;
                    }
                }
                if ($deep && $is_grp) {
                    $collect->($child_uuid);
                }
            }
        };
        $collect->($uuid);
        return wantarray ? @list : scalar(@list);
    }

    my $modelsort = $self->get_model();
    return wantarray ? () : 0 unless defined $modelsort;
    my $model = $modelsort->get_model();

    my @list;
    my $root;

    # Locate every node under $uuid
    $modelsort->foreach(sub {
        my ($store, $path, $iter, $tmp) = @_;
        my $node_uuid = $store->get_value($iter, 2);
        my $node_name = $store->get_value($iter, 1);
        $node_name =~s /<.+?> *//g;

        if ($node_uuid eq $uuid) {
            $root = $path->to_string();
        }
        if (!(defined $root && ($deep || $path->to_string() =~ /^$root:\d+$/g))) {
            return 0;
        }

        if ((($path->to_string() =~ /^$root:/g) && (((defined($$self{children}) || '0') eq $which) || ($which eq 'all') ) && ($node_uuid ne '__PAC__ROOT__'))) {
            if ($hash) {
                push(@list, {name=>$node_name,uuid=>$node_uuid});
            } else {
                push(@list, $node_uuid);
            }
        }
        return $path->to_string() !~ /^$root/g;
    });

    return wantarray ? @list : scalar(@list);
}

sub _getPath {
    my $self = shift;
    my $uuid = shift;

    return undef unless defined $uuid;

    my $modelsort = $self->get_model();
    return undef unless defined $modelsort;

    # Check cache first for O(1) response
    if ($$self{_path_cache} && $$self{_path_cache}{$uuid}) {
        my $ref = $$self{_path_cache}{$uuid};
        if ($ref->valid()) {
            return $ref->get_path();
        }
    }

    # Populate cache for all nodes in a single O(N) pass
    $$self{_path_cache} = {};
    $modelsort->foreach(sub {
        my ($store, $path, $iter) = @_;
        my $node_uuid = $store->get_value($iter, 2);
        if (defined $node_uuid) {
            $$self{_path_cache}{$node_uuid} = Gtk3::TreeRowReference->new($modelsort, $path);
        }
        return 0;
    });

    if ($$self{_path_cache}{$uuid} && $$self{_path_cache}{$uuid}->valid()) {
        return $$self{_path_cache}{$uuid}->get_path();
    }

    return undef;
}

sub _addNode {
    my $self = shift;
    my $parent_uuid = shift;
    my $new_uuid = shift;
    my $gui_name = shift;
    my $icon = shift;
    my $tree = shift // $$self{data};

    # Invalidate path cache on structure modification
    delete $$self{_path_cache};

    # Parent group is __PAC__ROOT__
    if ((! defined $parent_uuid) || ($parent_uuid eq '__PAC__ROOT__')) {
        push(@{$$self{'data'}}, {value => [$icon, $gui_name, $new_uuid]});
        return 1;
    }

    foreach my $elem_hash (@{$tree}) {
        my $this_uuid = $$elem_hash{'value'}[2];

        # Parent group found, insert here (the TreeModelSort will order it itself)
        if ($this_uuid eq $parent_uuid) {
            splice(@{$$elem_hash{'children'}}, 0, 0, ({value => [$icon, $gui_name, $new_uuid]}));
            return 1;
        }
        # Parent group not found, keep on searching in its children
        elsif ($$elem_hash{'children'} && @{$$elem_hash{'children'}}) {
            if ($self->_addNode($parent_uuid, $new_uuid, $gui_name, $icon, $$elem_hash{'children'})) {
                return 1;
            }
        }
    }

    return 0;
}

sub _delNode {
    my $self = shift;
    my $uuid = shift;

    my $modelsort = $self->get_model();
    my $model = $modelsort->get_model();

    # Attempt direct deletion via path cache first
    my $path = $self->_getPath($uuid);
    delete $$self{_path_cache};

    if ($path) {
        my $iter = $modelsort->get_iter($path);
        if ($iter) {
            my $child_iter = $modelsort->convert_iter_to_child_iter($iter);
            if ($child_iter) {
                $model->remove($child_iter);
                return 1;
            }
        }
    }

    # Fallback scan only if direct path resolution was not found
    $modelsort->foreach(sub {
        my ($store, $p, $iter, $tmp) = @_;
        my $node_uuid = $store->get_value($iter, 2);
        if ($node_uuid ne $uuid) {
            return 0;
        }
        $model->remove($modelsort->convert_iter_to_child_iter($modelsort->get_iter($p)));
        return 1;
    });

    return 1;
}

sub _focusPrevious {
    my $self        = shift;
    my $uuid        = shift;
    my $who         = shift;
    my $pg_expanded = 0;
    my $pg_depth    = 0;
    my $focus_path  = undef;

    if (!$uuid) {
        return 0;
    }
    my $model = $self->get_model();
    $model->foreach(
        sub {
            my ($store, $path, $iter) = @_;
            my $name      = $store->get_value($iter, 1);
            my $elem_uuid = $store->get_value($iter, 2);
            if ($who == 2) {
                $elem_uuid = $name;
            }
            my $group = ($name =~ /bold/) ? 1 : 0;
            my $expanded = $self->row_expanded($path);
            my $depth    = $path->get_depth() - 1;

            if ($elem_uuid eq $uuid) {
                return 1;
            }
            if ($group && $pg_expanded) {
                $focus_path  = $path->copy();
                $pg_depth    = $depth;
                $pg_expanded = $expanded;
            } elsif ($group && $depth <= $pg_depth) {
                $focus_path  = $path->copy();
                $pg_expanded = $expanded;
                $pg_depth    = $depth;
            } elsif ((!$group && $depth <= $pg_depth) || (!$group && $pg_expanded && $depth > $pg_depth)) {
                $focus_path  = $path->copy();
                $pg_depth    = $depth;
                $pg_expanded = 0;
            }
            return 0;
        }
    );

    if ($focus_path) {
        $self->set_cursor($focus_path, undef, 0);
        return 1;
    }

    return 0;
}

sub _focusNext {
    my $self  = shift;
    my $uuid  = shift;
    my $who   = shift;
    my $NEXT  = 0;
    my $level = -1;

    if (!$uuid) {
        return 0;
    }
    my $model = $self->get_model();
    $model->foreach(
        sub {
            my ($store, $path, $iter) = @_;
            my $name      = $store->get_value($iter, 1);
            my $elem_uuid = $store->get_value($iter, 2);
            if ($who == 2) {
                $elem_uuid = $name;
            }
            my $group = ($name =~ /bold/) ? 1 : 0;
            my $expanded = $self->row_expanded($path);
            my $depth    = $path->get_depth() - 1;

            if ($who && $uuid eq '__PAC__ROOT__') {
                $NEXT  = 1;
                $level = 99;
            }
            if ($NEXT) {
                if ($depth <= $level) {
                    $self->set_cursor($path, undef, 0);
                    return 1;
                }
                return 0;
            }
            if ($elem_uuid eq $uuid) {
                if ($group && !$expanded) {
                    $level = $depth;
                } else {
                    $level = 99;
                }
                $NEXT = 1;
            }
            return 0;
        }
    );
    return 0;
}

sub _setTreeFocus {
    my $self = shift;
    my $uuid = shift;

    return 0 unless defined $uuid;

    my $path = $self->_getPath($uuid);
    if ($path) {
        $self->expand_to_path($path);
        $self->set_cursor($path, undef, 0);
        return 1;
    }

    return 0;
}
# End of Ásbrú specific methods

sub new {
    if (!(@_ >= 3)) {
        croak "Usage: $_[0]\->new(title => type, ...)\n"
            . " expecting a list of column title and type name pairs.\n"
            . " can't create a SimpleTree with no columns";
    }
    return shift->new_from_treeview (Gtk3::TreeView->new(), @_);
}

sub new_from_treeview {
    my $class = shift;
    my $view = shift;

    if (!(defined ($view) and UNIVERSAL::isa ($view, 'Gtk3::TreeView'))) {
        croak "treeview is not a Gtk3::TreeView";
    }
    if (!(@_ >= 2)) {
        croak "Usage: $class\->new_from_treeview (treeview, title => type, ...)\n"
            . " expecting a treeview reference and list of column title and type name pairs.\n"
            . " can't create a SimpleTree with no columns";
    }

    # Defines a special column type that does not use a standard renderer
    # The renderer is built by function 'column_builder'
    # The renderer will assume the first attribute of the model is defining the icon to show
    # and the second attribute contains the markup text to display
    $class->add_column_type('image_text',
        type => 'Glib::Scalar',
        renderer => undef,
        column_builder => sub {
            my $pixrd = Gtk3::CellRendererPixbuf->new();
            my $txtrd = Gtk3::CellRendererText->new();
            my $column = Gtk3::TreeViewColumn->new();
            $column->pack_start($pixrd, 0);
            $column->pack_start($txtrd, 1);
            $column->add_attribute($pixrd, 'pixbuf', 0);
            $column->add_attribute($txtrd, 'markup', 1);
            return $column;
        }
    );

    # Build the columns list for this new tree
    # according to the definition of column types
    my @column_info = ();
    for (my $i = 0; $i < @_ ; $i+=2) {
        my $typekey = $_[$i+1];

        if (!$typekey) {
            croak "expecting pairs of title=>type";
        }
        if (!(exists $column_types{$typekey})) {
            croak "unknown column type $typekey, use one of " . join(", ", keys %column_types);
        }
        my $type = $column_types{$typekey}{type};
        if (not defined $type) {
            $type = 'Glib::String';
            carp "column type $typekey has no type field; did you"
               . " create a custom column type incorrectly?\n"
               . "limping along with $type";
        }
        push @column_info, {
            title => $_[$i],
            type => $type,
            rtype => $column_types{$_[$i+1]}{renderer},
            attr => $column_types{$_[$i+1]}{attr},
            column_builder => $column_types{$_[$i+1]}{column_builder},
        };
    }

    ## Create the store
    my $model = Gtk3::TreeStore->new(map {$_->{type}} @column_info);
    $view->set_model($model);

    ## Create view columns
    for (my $i = 0; $i < @column_info ; $i++) {
        if (!defined($column_info[$i]{rtype}) && defined($column_info[$i]{column_builder}) && ('CODE' eq ref $column_info[$i]{column_builder})) {
            # A column builder has been defined
            $view->append_column($column_info[$i]{column_builder}());
        }
        elsif ('CODE' eq ref $column_info[$i]{attr}) {
            $view->insert_column_with_data_func (-1,
                $column_info[$i]{title},
                $column_info[$i]{rtype}->new,
                $column_info[$i]{attr}, $i);
        } elsif ('hidden' eq $column_info[$i]{attr}) {
            # skip hidden column
        } else {
            my $column = Gtk3::TreeViewColumn->new_with_attributes (
                $column_info[$i]{title},
                $column_info[$i]{rtype}->new,
                $column_info[$i]{attr} => $i,
            );
            $view->append_column($column);

            if ($column_info[$i]{attr} eq 'active') {
                # make boolean columns respond to editing.
                my $r = $column->get_cells;
                $r->set (activatable => 1);
                $r->signal_connect(toggled => sub {
                    my ($renderer, $row, $col) = @_;
                    my $path = Gtk3::TreePath->new_from_string ($row);
                    my $iter = $model->get_iter ($path);
                    my $val = $model->get ($iter, $col);
                    $model->set($iter, $col, !$val);
                    }, $i);

            } elsif ($column_info[$i]{attr} eq 'text') {
                # attach a decent 'edited' callback to any
                # columns using a text renderer.  we do NOT
                # turn on editing by default.
                my $r = $column->get_cells;
                $r->{column} = $i;
                $r->signal_connect(edited => \&text_cell_edited, $model);
            }
        }
    }

    my @a;
    tie @a, 'TiedTree', $model;

    $view->{data} = \@a;
    return bless $view, $class;
}

sub text_cell_edited {
    my ($cell_renderer, $text_path, $new_text, $model) = @_;
    my $path = Gtk3::TreePath->new_from_string($text_path);
    my $iter = $model->get_iter($path);
    $model->set($iter, $cell_renderer->{column}, $new_text);
}

1;

__END__

=head1 NAME

PACTree - Ásbrú interface to Gtk3's complex MVC tree widget

=head1 ABSTRACT

PACTree is a simple interface to the powerful but complex Gtk3::TreeView
and Gtk3::TreeStore combination, implementing using tied arrays to make
thing simple and easy.
