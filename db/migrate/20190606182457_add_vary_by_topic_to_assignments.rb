
class AddVaryByTopicToAssignments < ActiveRecord::Migration[7.0]
  def change
    add_column :assignments, :vary_by_topic?, :boolean, default: false
  end
end