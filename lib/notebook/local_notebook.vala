using Gee;
using NaturalCollate;

public class Codex.LocalNotebook : Object, ListModel, NoteContainer, Notebook {

	public string name { get { return info.name; } }

	public string path {
		owned get { return _path; }
	}

	public string relative_path {
		owned get {
			return (_parent == null) ? info.name : @"$(_parent.relative_path)/$(info.name)";
		}
	}

	public NotebookInfo info {
		get { return _info; }
	}

	public Gee.List<Note>? loaded_notes {
		get { return _loaded_notes; }
	}

	ArrayList<Note>? _loaded_notes = null;
	ArrayList<Notebook>? _children = null;

	NotebookInfo _info;
	Provider provider;
	LocalNotebook? _parent;
	string _path;

	private bool disable_hidden_trash;
	private int note_sort_order;

	private Gdk.RGBA default_color = Gdk.RGBA ();

	construct {
		var settings = new Settings (Config.APP_ID);
		disable_hidden_trash = settings.get_boolean ("disable-hidden-trash");
		note_sort_order = settings.get_int ("note-sort-order");
		default_color.parse ("#2ec27eff");
	}

	public LocalNotebook (Provider provider, NotebookInfo info, LocalNotebook? parent = null) {
		this.provider = provider;
		this._info = info;
		this._parent = parent;
		this._path = (parent == null)
			? @"$(provider.notes_dir)/$(info.name)"
			: @"$(parent.path)/$(info.name)";
	}

	/**
	 * Immediate child notebooks (subfolders of this notebook). Lazily scanned
	 * and cached; call invalidate_children() after a rename/move to force a
	 * rescan on next access.
	 */
	public Gee.List<Notebook> get_child_notebooks () {
		if (_children != null) return _children;

		_children = new ArrayList<Notebook> ();
		var dir = File.new_for_path (_path);

		if (!dir.query_exists ()) return _children;

		try {
			var enumerator = dir.enumerate_children (FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.TIME_MODIFIED + "," + FileAttribute.STANDARD_DISPLAY_NAME, 0);
			FileInfo file_info;
			while ((file_info = enumerator.next_file ()) != null) {
				if (file_info.get_file_type () != FileType.DIRECTORY) continue;
				var child_name = file_info.get_display_name ();
				if (disable_hidden_trash && child_name == "Trash") continue;
				if (child_name[0] == '.') continue;
				if (child_name == ".trash" || child_name == "Trash") continue;
				var time = file_info.get_modification_date_time ();
				var child_path = @"$_path/$child_name";
				_children.add (new LocalNotebook (
					provider,
					read_notebook_info (child_name, time, child_path),
					this
				));
			}
		} catch (Error err) {
			stderr.printf ("Error: get_child_notebooks failed for %s: %s\n", _path, err.message);
		}

		return _children;
	}

	/** Clears the cached child list, forcing a rescan on next get_child_notebooks() call. */
	public void invalidate_children () {
		_children = null;
	}

	public void load () {
		if (_loaded_notes != null) return;
		_loaded_notes = new ArrayList<Note> ();
		var dir = File.new_for_path (path);
		try {
			var enumerator = dir.enumerate_children (FileAttribute.STANDARD_NAME + "," + FileAttribute.TIME_MODIFIED + "," + FileAttribute.STANDARD_CONTENT_TYPE + "," + FileAttribute.STANDARD_DISPLAY_NAME, 0);
			FileInfo file_info;
			while ((file_info = enumerator.next_file ()) != null) {
				var content_type = file_info.get_content_type ();
				if (content_type == null || !(content_type.has_prefix ("text") || content_type.has_prefix ("application")))
					continue;
				var name = file_info.get_display_name ();
				if (name[0] == '.')
					continue;
				var dot_i = name.last_index_of_char ('.');
				if (dot_i == -1)
					continue;
				var extension = name.substring (dot_i + 1);
				name = name.substring (0, dot_i);
				var mod_time = (!) file_info.get_modification_date_time ().to_timezone (new TimeZone.local ());
				_loaded_notes.add (new Note (
					name,
					extension,
					this,
					mod_time
				));
			}
		} catch (Error e) {
			error (@"Notebook loading failed: $(e.message)\n");
		}
		sort_notes (note_sort_order);
	}

	public void sort_notes (int note_sort_order) {
		this.note_sort_order = note_sort_order;

		switch (note_sort_order) {
			case 1:
				_loaded_notes.sort ((a, b) => a.time_modified.compare(b.time_modified));
				break;
			case 2:
				_loaded_notes.sort ((a, b) => strcmp (a.name, b.name));
				break;
			case 3:
				_loaded_notes.sort ((a, b) => strcmp (b.name, a.name));
				break;
			case 4:
				_loaded_notes.sort ((a, b) => NaturalCollate.compare (a.name, b.name));
				break;
			case 5:
				_loaded_notes.sort ((a, b) => NaturalCollate.compare (b.name, a.name));
				break;
			default:
				_loaded_notes.sort ((a, b) => b.time_modified.compare(a.time_modified));
				break;
		}
	}

	public void unload () {
		_loaded_notes = null;
	}

	public void change (Provider provider, NotebookInfo info) {
		this.provider = provider;
		this._info = info;
		this._path = (_parent == null)
			? @"$(provider.notes_dir)/$(info.name)"
			: @"$(_parent.path)/$(info.name)";
	}

	public Note new_note (string name, string extension) throws ProviderError {
		load ();
		var file_name = @"$name.$extension";
		var path = @"$path/$file_name";
		var file = File.new_for_path (path);
		if (file.query_exists ()) {
			throw new ProviderError.ALREADY_EXISTS (@"Note \"$name\" already exists in $(this.name)");
		}
		try {
			file.create (FileCreateFlags.NONE);
		} catch (Error e) {
			 throw new ProviderError.COULDNT_CREATE_FILE("Couldn't create note at \"$path\"");
		}
		var note = new Note (name, extension, this, new DateTime.now ());
		_loaded_notes.insert (0, note);
		items_changed (0, 0, 1);
		return note;
	}

	public void change_note (Note note, string name, string extension) throws ProviderError {
		load ();
		if (note.name != name || note.extension != extension) {
			var original_path = note.path;
			var original_file = File.new_for_path (original_path);
			var file_name = @"$name.$extension";
			var path = @"$path/$file_name";
			var file = File.new_for_path (path);
			if (file.query_exists ()) {
				throw new ProviderError.ALREADY_EXISTS (@"Note at $path already exists");
			}
			try {
				original_file.set_display_name(file_name);
			} catch (Error e) {
				throw new ProviderError.COULDNT_CREATE_FILE (@"Couldn't change $original_path to $path: $(e.message)");
			}

			note.change (name, extension, this, new DateTime.now ());
			int i = _loaded_notes.index_of (note);
			items_changed (i, 1, 1);
		}
	}

	public void delete_note (Note note) throws ProviderError {
		load ();
		var path = note.path;
		var file = File.new_for_path (path);
		if (!file.query_exists ()) {
			throw new ProviderError.COULDNT_DELETE (@"Couldn't delete note at $path");
		}
		var trashed_dir_path = "";
		var encoded_notebook_path = Trash.encode_notebook_path (note.notebook.relative_path);
		if (disable_hidden_trash) {
			trashed_dir_path = @"$(provider.trash_dir)/Trash/$encoded_notebook_path";
		} else {
			trashed_dir_path = @"$(provider.trash_dir)/.trash/$encoded_notebook_path";
		}
		var trashed_path = @"$trashed_dir_path/$(note.file_name)";
		try {
			var trashed_dir = File.new_for_path (trashed_dir_path);
			if (!trashed_dir.query_exists ()) {
				trashed_dir.make_directory_with_parents ();
			}
			var trashed_file = File.new_for_path (trashed_path);
			file.move (trashed_file, FileCopyFlags.OVERWRITE);
			provider.trash.unload ();
		} catch (Error e) {
			throw new ProviderError.COULDNT_DELETE (@"Couldn't move note from $path, to $trashed_path");
		}
		int i = _loaded_notes.index_of (note);
		_loaded_notes.remove_at (i);
		items_changed (i, 1, 0);
	}

	public Type get_item_type () {
		return typeof (Note);
	}

	public uint get_n_items () {
		load ();
		if (_loaded_notes == null)
			error (@"Notebook \"$name\": Notes haven't loaded yet");
		return _loaded_notes.size;
	}

	public uint get_index_of(Note? note){
		load ();
		if (note != null && _loaded_notes != null){
			return loaded_notes.index_of (note);
		}
		return -1;
	}

	public Object? get_item (uint i) {
		load ();
		if (_loaded_notes == null)
			error (@"Notebook \"$name\": Notes haven't loaded yet");
		return (i >= _loaded_notes.size) ? null : _loaded_notes.@get((int) i);
	}

	private NotebookInfo read_notebook_info (string name, DateTime time_modified, string notebook_path) {
		return new NotebookInfo (
			name,
			read_color (notebook_path),
			read_icon_type (notebook_path),
			read_data_file (notebook_path, "icon_name"),
			time_modified,
			read_data_file (notebook_path, "custom_icon_label")
		);
	}

	private Gdk.RGBA read_color (string notebook_path) {
		var data = read_data_file (notebook_path, "color");
		if (data == null) {
			return default_color;
		}
		var rgba = Gdk.RGBA ();
		if (!rgba.parse (data.strip ())) {
			return default_color;
		}
		return rgba;
	}

	private NotebookIconType read_icon_type (string notebook_path) {
		var data = read_data_file (notebook_path, "icon_type");
		if (data == null) {
			return NotebookIconType.DEFAULT;
		}
		return NotebookIconType.from_string (data);
	}

	private string? read_data_file (string notebook_path, string data_name) {
		var path = @"$notebook_path/.config/$data_name";
		var f = File.new_for_path (path);
		if (!f.query_exists ())
			return null;
		try {
			string etag_out;
			uint8[] text_data = {};
			f.load_contents (null, out text_data, out etag_out);
			return (string) text_data;
		} catch (Error e) {
			return null;
		}
	}
}