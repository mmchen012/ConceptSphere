function move_gemini_exports() {
    try {
        var default_folder_id = "1RvV-36a4QoWBoXkC9SfyJT6sRSJJ-d9T";
        var ide_gui_folder_id = "1hMB2OEuapYqeTSnaXtNzBeCr4fLFWWnY";
        var gui_files = ["window.py", "editor.py"];
        
        var root_folder = DriveApp.getRootFolder();
        var files = root_folder.getFiles();
        
        // Count how many files we find (for debugging)
        var count = 0;

        while (files.hasNext()) {
            var file = files.next();
            var file_name = file.getName();
            var file_type = file.getMimeType();
            
            // REMOVED the 2-minute check for testing purposes
            count++;
            
            // 1. Determine destination
            var is_gui_file = gui_files.indexOf(file_name) !== -1;
            var dest_folder = is_gui_file ? DriveApp.getFolderById(ide_gui_folder_id) : DriveApp.getFolderById(default_folder_id);

            // 2. Setup Email Details
            var attachments = [];
            var body_msg = "File '" + file_name + "' was moved to: " + dest_folder.getName();

            // 3. Version Check
            var existing_files = dest_folder.getFilesByName(file_name);
            if (existing_files.hasNext()) {
                var old_file = existing_files.next();
                try {
                    attachments.push(old_file.getAs(file_type));
                    body_msg += "\n\nNOTE: Older version attached.";
                } catch (e) {
                    body_msg += "\n\nNOTE: Could not attach older version (Type: " + file_type + ")";
                }
            }

            // 4. Move and Email
            file.moveTo(dest_folder);
            
            MailApp.sendEmail({
                to: Session.getActiveUser().getEmail(),
                subject: "File Moved: " + file_name,
                body: body_msg,
                attachments: attachments
            });
            
            console.log("Processed: " + file_name);
        }
        
        if (count === 0) {
            console.log("No files were found in the root directory to move.");
        }

    } catch (err) {
        console.log("ERROR: " + err.toString());
    }
}