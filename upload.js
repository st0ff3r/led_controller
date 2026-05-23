var source; // Global variable for EventSource

function _(element) {
	return document.getElementById(element);
}

// Trigger hidden file input when clicking the drag & drop area
_('drag_drop').onclick = function(event) {
	// Avoid triggering input click again if elements inside are clicked
	if (event.target.id === 'drag_drop' || event.target.tagName === 'DIV') {
		_('file_input').click();
	}
};

// Handle file selection via standard file dialog
_('file_input').onchange = function(event) {
	var select_files = event.target.files;
	if (select_files.length > 0) {
		handleFileUpload(select_files[0]);
	}
};

// Drag and Drop event handlers
_('drag_drop').ondragover = function(event) {
	event.preventDefault(); // Required to allow dropping
	this.style.borderColor = '#333';
	return false;
};

_('drag_drop').ondragleave = function(event) {
	this.style.borderColor = '#ccc';
	return false;
};

_('drag_drop').ondrop = function(event) {
	event.preventDefault();
	var drop_files = event.dataTransfer.files;
	
	if (drop_files.length <= 1) {
		handleFileUpload(drop_files[0]);
	} else {
		showUploadError('<div class="alert alert-danger"><b>only supports upload of one file</div>');
	}
};

// Core Upload and Progress Handler Function
function handleFileUpload(file) {
	var form_data = new FormData();
	form_data.append("movie_file", file);

	_('progress_bar').style.display = 'block';
	var ajax_request = new XMLHttpRequest();
	ajax_request.open("post", "upload");

	ajax_request.addEventListener('error', function(event) {
		console.log("An error occurred while attempting to connect. " + event.data);
		resetProgressBar();
	});

	ajax_request.addEventListener('load', function(event) {
		if (ajax_request.status < 400) {
			_('uploaded_image').innerHTML = '';
		} else {
			showUploadError('<div class="alert alert-danger"><b>allready running</div>');
		}
	});
	
	// Server-Sent Events for progress tracking
	source = new EventSource('progress');
	
	source.addEventListener('error', function(event) {
		console.log("An error occurred while attempting to connect. " + event.data);
		source.close();
		resetProgressBar();
	});

	source.addEventListener('message', function(event) {
		console.log(event.data);
		var percent_completed = Math.round(event.data);
		
		if (!isNaN(percent_completed)) {
			_('progress_bar_process').style.width = percent_completed + '%';
			_('progress_bar_process').innerHTML = percent_completed + '%';
		} else if (event.data == "DONE") {
			source.close();
			resetProgressBar();
			
			var unique = Date.now();
			_('slitscan').src = 'images/slitscan.png?' + unique;
		} else if (event.data == "ERROR") {
			source.close();
			resetProgressBar();
			showUploadError('<div class="alert alert-danger"><b>server side processing failed</div>');
		}
	}, false);

	ajax_request.send(form_data);
}

// Helper function to reset UI progress
function resetProgressBar() {
	_('progress_bar').style.display = 'none';
	_('progress_bar_process').style.width = '0%';
	_('progress_bar_process').innerHTML = '';
	_('drag_drop').style.borderColor = '#ccc';
	_('file_input').value = ''; // Reset input so same file can be re-uploaded
}

// Helper function to show errors
function showUploadError(errorMessage) {
	_('uploaded_image').style.display = 'block';
	_('uploaded_image').innerHTML = errorMessage;
	_('drag_drop').style.borderColor = '#ccc';

	setTimeout(function() {
		_('uploaded_image').innerHTML = '';
	}, 3000);
}
